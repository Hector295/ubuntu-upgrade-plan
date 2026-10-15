#!/bin/sh
# os-upgrade: in-place upgrade of Ubuntu to the next LTS (22.04 -> 24.04 or
# 24.04 -> 26.04, depending on TARGET_VERSION) with a pinned kernel
# (KERNEL_VERSION) on RKE2 nodes. Run by system-upgrade-controller (SUC) inside
# "chroot /host", so all paths are host paths.
#
# Subcommands:
#   prepare       initContainer of the upgrade Plan. Runs BEFORE the drain: if something
#                 prevents the upgrade, it fails without cordoning or draining the node.
#   predownload   Plan without drain or reboot: downloads the target release packages and the
#                 kernel to local disk, so the upgrade window does not depend on the network.
#   upgrade       main container. Idempotent state machine: every reboot kills the pod,
#                 the Job creates another one and the script resumes where it left off.
#   host-phase    run by systemd on the host (transient unit) so that do-release-upgrade
#                 survives the pod. Not called by hand.
#   status        shows the node state (diagnostics).
#   reset-failed  clears the failure mark and the reboot counter after a manual review.
#
# Configuration: environment variables (the Plan ConfigMap). See docs/configuration.md.
set -eu

# ------------------------------------------------------------------ configuration
# ROOT is only used by the tests (fake root); on the node it is always empty.
ROOT="${ROOT:-}"

KERNEL_VERSION="${KERNEL_VERSION:-}"
SINGLE_REBOOT="${SINGLE_REBOOT:-true}"
REQUIRE_PREDOWNLOAD="${REQUIRE_PREDOWNLOAD:-true}"
APT_MIRROR="${APT_MIRROR:-}"
HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"
MIN_FREE_ROOT_MB="${MIN_FREE_ROOT_MB:-5000}"
MIN_FREE_BOOT_MB="${MIN_FREE_BOOT_MB:-300}"
MAX_REBOOTS="${MAX_REBOOTS:-3}"
# true: do-release-upgrade --allow-third-party. Keeps sources that are not public Ubuntu
# mirrors (internal mirror, vendor repos) if they publish the target release; without it the
# upgrader disables them and switches to archive.ubuntu.com.
ALLOW_THIRD_PARTY="${ALLOW_THIRD_PARTY:-true}"
POST_UPGRADE_HOOK_RETRIES="${POST_UPGRADE_HOOK_RETRIES:-3}"
POST_UPGRADE_HOOK_SLEEP="${POST_UPGRADE_HOOK_SLEEP:-20}"
# After the reboot the Job pod starts before rke2 is up (still "activating" while it
# rejoins etcd): wait up to this limit before failing the finalize step.
RKE2_WAIT_SECONDS="${RKE2_WAIT_SECONDS:-600}"
RKE2_WAIT_INTERVAL="${RKE2_WAIT_INTERVAL:-10}"

TARGET_VERSION="${TARGET_VERSION:-24.04}"

# Supported transitions: source|target|target codename|pinned kernel packages
# (%s = KERNEL_VERSION). do-release-upgrade only jumps to the next LTS.
#   24.04: linux-modules-extra carries the modules that are not in linux-modules.
#   26.04: linux-modules-extra no longer exists (everything is in linux-modules); the ZFS
#          modules are a separate package that the metapackage installs by default.
TRANSITIONS="
22.04|24.04|noble|linux-image-%s linux-modules-%s linux-modules-extra-%s
24.04|26.04|resolute|linux-image-%s linux-modules-%s linux-main-modules-zfs-%s
"
SOURCE_VERSION=""
TARGET_CODENAME=""
KERNEL_PACKAGES_TEMPLATE=""

# Keys saved to disk so that host-phase (outside the pod) uses the same configuration.
CONFIG_KEYS="KERNEL_VERSION TARGET_VERSION SINGLE_REBOOT REQUIRE_PREDOWNLOAD APT_MIRROR HTTP_PROXY HTTPS_PROXY NO_PROXY MIN_FREE_ROOT_MB MIN_FREE_BOOT_MB MAX_REBOOTS ALLOW_THIRD_PARTY POST_UPGRADE_HOOK_RETRIES"

# ------------------------------------------------------------------ host paths
STATE_DIR="$ROOT/var/lib/os-upgrade"
CONFIG_FILE="$STATE_DIR/config"
FAILED_FILE="$STATE_DIR/failed"
REBOOTS_FILE="$STATE_DIR/reboots"
DONE_FILE="$STATE_DIR/done"
PREDOWNLOAD_FILE="$STATE_DIR/predownload.ok"
RELEASE_STARTED_FILE="$STATE_DIR/release-upgrade.started"
RELEASE_DONE_FILE="$STATE_DIR/release-upgrade.done"
TIMERS_STATE_FILE="$STATE_DIR/timers.state"
ARCHIVES_DIR="$STATE_DIR/archives"
ALT_APT_DIR="$STATE_DIR/apt"
STARTED_AT_FILE="$STATE_DIR/started-at"
# Log of every phase in key=value format (survives reboots) and final report.
LOG_FILE="$ROOT/var/log/os-upgrade.log"
REPORT_FILE="$ROOT/var/log/os-upgrade-report.txt"

HOST_SCRIPT_PATH="/usr/local/sbin/os-upgrade.sh"     # path as seen by the host systemd
HOST_SCRIPT="$ROOT$HOST_SCRIPT_PATH"
UNIT="os-upgrade-release"

OS_RELEASE="$ROOT/etc/os-release"
APT_CACHE_DIR="$ROOT/var/cache/apt/archives"
APT_CONF_FILE="$ROOT/etc/apt/apt.conf.d/99-os-upgrade"
PIN_FILE="$ROOT/etc/apt/preferences.d/99-os-upgrade-kernel"
NEEDRESTART_FILE="$ROOT/etc/needrestart/conf.d/99-os-upgrade.conf"
RELEASE_UPGRADES_FILE="$ROOT/etc/update-manager/release-upgrades"
GRUB_DEFAULT_FILE="$ROOT/etc/default/grub.d/99-os-upgrade-kernel.cfg"
GRUB_CFG="$ROOT/boot/grub/grub.cfg"
REBOOT_REQUIRED_PKGS="$ROOT/run/reboot-required.pkgs"

# Kernel metapackages always pull in the newest kernel, so they are removed and blocked
# with Pin-Priority -1 to keep KERNEL_VERSION as the only kernel.
KERNEL_META_GLOBS="linux-generic* linux-image-generic* linux-headers-generic* linux-signed-generic* linux-signed-image-generic* linux-virtual* linux-image-virtual* linux-headers-virtual*"
# Packages pulled in by the metapackages that must not be orphaned (autoremove).
KEEP_MANUAL_PKGS="linux-firmware intel-microcode amd64-microcode"
# Timers that trigger unattended-upgrades; disabled during the process and restored afterwards.
APT_TIMERS="apt-daily.timer apt-daily-upgrade.timer"

SELF="$0"
PHASE="${1:-}"
# Optional hook from the overlay: shipped in the same Secret as this script.
POST_UPGRADE_HOOK_FILE="${POST_UPGRADE_HOOK_FILE:-$(dirname "$SELF")/post-upgrade-hook.sh}"

export DEBIAN_FRONTEND=noninteractive
export RELEASE_UPGRADER_NO_SCREEN=1

# ------------------------------------------------------------------ utilities
# Readable output in the pod; in the host file, one key=value line per event:
#   ts=... node=... phase=... level=... msg="..."
log() {
  level=$1
  shift
  ts=$(date -Is)
  echo "$ts $(hostname) ${PHASE:-?} $level $*"
  msg=$(printf '%s' "$*" | sed 's/\\/\\\\/g; s/"/\\"/g')
  { mkdir -p "$(dirname "$LOG_FILE")" \
      && printf 'ts=%s node=%s phase=%s level=%s msg="%s"\n' "$ts" "$(hostname)" "${PHASE:-?}" "$level" "$msg" >> "$LOG_FILE"
  } 2>/dev/null || true
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
# Step marker: "STEP 3/7: ..." to follow progress in the pod logs.
step() { log INFO "STEP $1: $2"; }

# Retryable error: the Job tries again, no mark is left.
die() {
  log ERROR "$@"
  exit 1
}

# Error that needs a human: leaves the mark and every retry stops here.
fail_hard() {
  log ERROR "$@"
  mkdir -p "$STATE_DIR"
  printf '%s %s: %s\n' "$(date -Is)" "$PHASE" "$*" > "$FAILED_FILE"
  log ERROR "Node marked as failed ($FAILED_FILE). Review it, then run: sh $HOST_SCRIPT_PATH reset-failed"
  exit 1
}

apt_get() {
  apt-get -y -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

is_true() { [ "$1" = "true" ]; }

# shellcheck disable=SC1090
os_version() { ( . "$OS_RELEASE"; echo "$VERSION_ID" ); }

running_kernel() { uname -r; }

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

# Installed, held or not: a package with apt-mark hold has ${Status} "hold ok installed"
# (not "install ok installed"); ${db:Status-Status} is "installed" in both cases.
pkg_installed() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = "installed" ]
}

# Installed packages matching the given patterns. In ${db:Status-Abbrev} the second letter
# is the state ("i" = installed); the first one is the selection ("i" normal, "h" hold).
installed_matching() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null \
    | awk 'substr($1, 2, 1) == "i" {print $2}' || true
}

kernel_packages() {
  echo "$KERNEL_PACKAGES_TEMPLATE" | sed "s/%s/$KERNEL_VERSION/g"
}

# Derives the source release, codename and kernel packages from TARGET_VERSION.
resolve_transition() {
  line=$(echo "$TRANSITIONS" | awk -F'|' -v t="$TARGET_VERSION" '$2 == t')
  [ -n "$line" ] || die "unsupported TARGET_VERSION: '$TARGET_VERSION' (supported: $(echo "$TRANSITIONS" | awk -F'|' 'NF {printf "%s ", $2}'))"
  SOURCE_VERSION=$(echo "$line" | cut -d'|' -f1)
  TARGET_CODENAME=$(echo "$line" | cut -d'|' -f3)
  KERNEL_PACKAGES_TEMPLATE=$(echo "$line" | cut -d'|' -f4)
}

# The node release is valid for the process: the source one or the target one (kernel change only).
check_version_supported() {
  v=$1
  case "$v" in
    "$SOURCE_VERSION"|"$TARGET_VERSION") return 0 ;;
  esac
  if echo "$TRANSITIONS" | awk -F'|' -v v="$v" '$1 == v {f = 1} END {exit !f}'; then
    die "the node is on $v and the target is $TARGET_VERSION: do-release-upgrade only jumps to the next LTS; upgrade it to $SOURCE_VERSION first (TARGET_VERSION=$SOURCE_VERSION)"
  fi
  die "unsupported release: $v (expected $SOURCE_VERSION or $TARGET_VERSION)"
}

kernel_installed() {
  for p in $(kernel_packages); do
    pkg_installed "$p" || return 1
  done
}

unit_active() { systemctl is-active --quiet "$UNIT"; }

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

export_proxy_env() {
  if [ -n "$HTTP_PROXY" ]; then export HTTP_PROXY http_proxy="$HTTP_PROXY"; fi
  if [ -n "$HTTPS_PROXY" ]; then export HTTPS_PROXY https_proxy="$HTTPS_PROXY"; fi
  if [ -n "$NO_PROXY" ]; then export NO_PROXY no_proxy="$NO_PROXY"; fi
}

# ------------------------------------------------------------------ configuration checks
validate_config() {
  [ -n "$KERNEL_VERSION" ] || die "KERNEL_VERSION is not set (e.g. 6.8.0-139-generic)"
  echo "$KERNEL_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$' \
    || die "invalid KERNEL_VERSION: '$KERNEL_VERSION' (expected format: 6.8.0-139-generic)"
  for v in SINGLE_REBOOT REQUIRE_PREDOWNLOAD ALLOW_THIRD_PARTY; do
    eval "val=\$$v"
    # shellcheck disable=SC2154 # val is assigned by eval
    case "$val" in true|false) ;; *) die "$v must be true or false (value: '$val')" ;; esac
  done
  for v in MIN_FREE_ROOT_MB MIN_FREE_BOOT_MB MAX_REBOOTS POST_UPGRADE_HOOK_RETRIES; do
    eval "val=\$$v"
    case "$val" in ''|*[!0-9]*) die "$v must be an integer (value: '$val')" ;; esac
  done
  resolve_transition
}

write_config() {
  mkdir -p "$STATE_DIR"
  tmp="$CONFIG_FILE.tmp"
  : > "$tmp"
  for k in $CONFIG_KEYS; do
    eval "val=\$$k"
    printf '%s=%s\n' "$k" "$(shell_quote "$val")" >> "$tmp"
  done
  mv "$tmp" "$CONFIG_FILE"
}

load_config() {
  [ -f "$CONFIG_FILE" ] || fail_hard "$CONFIG_FILE does not exist"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  resolve_transition
}

# ------------------------------------------------------------------ state
release_upgrade_interrupted() {
  [ -f "$RELEASE_STARTED_FILE" ] && [ ! -f "$RELEASE_DONE_FILE" ] && ! unit_active
}

is_done() {
  [ "$(os_version)" = "$TARGET_VERSION" ] || return 1
  [ "$(running_kernel)" = "$KERNEL_VERSION" ] || return 1
  kernel_installed || return 1
  ! unit_active || return 1
  ! release_upgrade_interrupted || return 1
}

check_not_failed() {
  if [ -f "$FAILED_FILE" ]; then
    die "the node is marked as failed: $(cat "$FAILED_FILE"). Review it, then run: sh $HOST_SCRIPT_PATH reset-failed"
  fi
}

check_space() {
  root_free=$(free_mb "$ROOT/")
  boot_free=$(free_mb "$ROOT/boot")
  [ "$root_free" -ge "$MIN_FREE_ROOT_MB" ] \
    || die "not enough free space on /: $root_free MB (minimum $MIN_FREE_ROOT_MB)"
  [ "$boot_free" -ge "$MIN_FREE_BOOT_MB" ] \
    || die "not enough free space on /boot: $boot_free MB (minimum $MIN_FREE_BOOT_MB)"
}

# do-release-upgrade refuses to start if a reboot is pending because of these packages.
filter_reboot_pkgs() { grep -Ex 'libc6|linux-base|linux-image-.*' || true; }

pending_reboot_pkgs() {
  [ -f "$REBOOT_REQUIRED_PKGS" ] || return 0
  filter_reboot_pkgs < "$REBOOT_REQUIRED_PKGS" | sort -u
}

# Packages the source release full-upgrade would install that would force a prior
# reboot. Simulated with the kernel pin, as the real run will do.
simulated_reboot_pkgs() {
  pin_tmp="$STATE_DIR/sim-preferences"
  write_pin_file "$pin_tmp"
  apt-get -s -o Dir::Etc::Preferences="$pin_tmp" full-upgrade 2>/dev/null \
    | awk '/^Inst / {print $2}' | filter_reboot_pkgs | sort -u
  rm -f "$pin_tmp"
}

predownload_matches() {
  [ -f "$PREDOWNLOAD_FILE" ] || return 1
  grep -qx "KERNEL_VERSION=$KERNEL_VERSION" "$PREDOWNLOAD_FILE" || return 1
  grep -qx "TARGET_VERSION=$TARGET_VERSION" "$PREDOWNLOAD_FILE" || return 1
  for p in $(kernel_packages); do
    ls "$ARCHIVES_DIR/${p}_"*.deb >/dev/null 2>&1 || return 1
  done
}

# ------------------------------------------------------------------ apt sources
# Configured sources: "file<TAB>uri<TAB>suites<TAB>state" (state: on|off).
# Understands sources.list/*.list (one line per entry) and *.sources (deb822).
list_sources() {
  for f in "$ROOT/etc/apt/sources.list" "$ROOT"/etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    awk -v f="${f#"$ROOT"}" '
      /^[[:space:]]*deb[[:space:]]/ {
        sub(/\[[^]]*\]/, ""); print f "\t" $2 "\t" $3 "\ton"; next }
      /^#[[:space:]]*deb[[:space:]].*disabled on upgrade/ {
        sub(/^#[[:space:]]*/, ""); sub(/\[[^]]*\]/, ""); print f "\t" $2 "\t" $3 "\toff" }
    ' "$f"
  done
  for f in "$ROOT"/etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    awk -v f="${f#"$ROOT"}" '
      function flush() { if (uris != "") { n = split(uris, u, " "); for (i = 1; i <= n; i++) print f "\t" u[i] "\t" suites "\t" (enabled ? "on" : "off") } uris = ""; suites = ""; enabled = 1 }
      BEGIN { enabled = 1 }
      /^[[:space:]]*$/ { flush(); next }
      /^Enabled:/ { enabled = ($2 != "no") }
      /^URIs:/ { $1 = ""; sub(/^ /, ""); uris = $0 }
      /^Suites:/ { $1 = ""; sub(/^ /, ""); suites = $0 }
      END { flush() }
    ' "$f"
  done
}

# Public Ubuntu mirrors (what do-release-upgrade accepts without --allow-third-party).
is_official_uri() {
  echo "$1" | grep -Eq '^[a-z]+://([a-z0-9-]+\.)*(archive|security|ports)\.ubuntu\.com(/|$)'
}

third_party_sources() {
  list_sources | awk -F'\t' '$4 == "on"' | while IFS="$(printf '\t')" read -r file uri suites _; do
    is_official_uri "$uri" || echo "$uri ($suites, $file)"
  done | sort -u
}

disabled_sources() {
  list_sources | awk -F'\t' '$4 == "off" {print $2 " (" $3 ", " $1 ")"}' | sort -u
}

# Reports the sources that are not public Ubuntu mirrors and how the upgrade will treat
# them. Without ALLOW_THIRD_PARTY an internal Ubuntu mirror would be disabled: stop.
check_sources() {
  tp=$(third_party_sources)
  [ -n "$tp" ] || return 0
  if is_true "$ALLOW_THIRD_PARTY"; then
    info "unofficial sources (kept if they publish $TARGET_CODENAME, disabled otherwise): $(echo "$tp" | tr '\n' ';')"
    return 0
  fi
  mirror=$(APT_MIRROR="" detect_mirror)
  if ! is_official_uri "$mirror"; then
    die "the node Ubuntu mirror ($mirror) is not a public mirror: with ALLOW_THIRD_PARTY=false do-release-upgrade would disable it and use archive.ubuntu.com. Use ALLOW_THIRD_PARTY=true"
  fi
  warn "unofficial sources the upgrade will disable (ALLOW_THIRD_PARTY=false): $(echo "$tp" | tr '\n' ';')"
}

# Held packages (apt-mark hold) other than the pinned kernel: they can block the release upgrade.
held_packages() {
  apt-mark showhold 2>/dev/null | grep -vxF "$(kernel_packages | tr ' ' '\n')" | sort -u || true
}

check_held() {
  held=$(held_packages)
  [ -z "$held" ] || warn "held packages (apt-mark hold) that can block the release upgrade: $(echo "$held" | tr '\n' ' ')"
}

# ------------------------------------------------------------------ post-upgrade hook
check_hook_syntax() {
  [ -f "$POST_UPGRADE_HOOK_FILE" ] || return 0
  sh -n "$POST_UPGRADE_HOOK_FILE" 2>/dev/null \
    || die "the post-upgrade hook has syntax errors: $POST_UPGRADE_HOOK_FILE"
}

# Runs the overlay hook (if any) with retries. If it does not pass, the node is marked:
# the system is upgraded but something specific to the environment does not work.
run_post_upgrade_hook() {
  [ -f "$POST_UPGRADE_HOOK_FILE" ] || { HOOK_RESULT="no hook"; return 0; }
  attempt=1
  while :; do
    info "Post-upgrade hook (attempt $attempt/$POST_UPGRADE_HOOK_RETRIES)"
    if out=$(NODE_NAME="${SYSTEM_UPGRADE_NODE_NAME:-$(hostname)}" KERNEL_VERSION="$KERNEL_VERSION" \
        TARGET_VERSION="$TARGET_VERSION" sh "$POST_UPGRADE_HOOK_FILE" 2>&1); then
      echo "$out" | while IFS= read -r l; do info "hook: $l"; done
      HOOK_RESULT="OK"
      return 0
    fi
    echo "$out" | while IFS= read -r l; do warn "hook: $l"; done
    if [ "$attempt" -ge "$POST_UPGRADE_HOOK_RETRIES" ]; then
      fail_hard "the post-upgrade hook failed $attempt times; the system is on $TARGET_VERSION but the custom check does not pass"
    fi
    attempt=$((attempt + 1))
    sleep "$POST_UPGRADE_HOOK_SLEEP"
  done
}

rke2_active() { systemctl is-active --quiet rke2-server || systemctl is-active --quiet rke2-agent; }

wait_rke2_active() {
  waited=0
  until rke2_active; do
    if [ "$waited" -ge "$RKE2_WAIT_SECONDS" ]; then
      die "rke2 is not active after $RKE2_WAIT_SECONDS s; see journalctl -u rke2-server (or rke2-agent)"
    fi
    [ "$waited" -gt 0 ] || info "waiting for rke2 to become active (up to $RKE2_WAIT_SECONDS s)"
    sleep "$RKE2_WAIT_INTERVAL"
    waited=$((waited + RKE2_WAIT_INTERVAL))
    [ "$RKE2_WAIT_INTERVAL" -gt 0 ] || waited=$((waited + 1))
  done
}

# ------------------------------------------------------------------ reboot
reboot_now() {
  n=$(cat "$REBOOTS_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$REBOOTS_FILE"
  [ "$n" -le "$MAX_REBOOTS" ] || fail_hard "too many reboots ($n > $MAX_REBOOTS); possible loop"
  info "Rebooting ($n/$MAX_REBOOTS): $1"
  sync
  systemctl reboot || reboot
  sleep infinity
  die "the reboot did not happen"
}

# ------------------------------------------------------------------ host preparation
configure_host() {
  mkdir -p "$(dirname "$APT_CONF_FILE")" "$(dirname "$NEEDRESTART_FILE")"
  # Always keep the existing configuration files.
  cat > "$APT_CONF_FILE" <<'EOF'
// Managed by os-upgrade; removed when it finishes.
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF
  # needrestart only lists; it must not restart services (rke2) on its own.
  echo "\$nrconf{restart} = 'l';" > "$NEEDRESTART_FILE"
  if [ -f "$RELEASE_UPGRADES_FILE" ]; then
    sed -i 's/^Prompt=.*/Prompt=lts/' "$RELEASE_UPGRADES_FILE"
  fi
  # unattended-upgrades is triggered by these timers: disable them and save their original
  # state (only the first time) to restore it at the end.
  if [ ! -f "$TIMERS_STATE_FILE" ]; then
    for t in $APT_TIMERS; do
      echo "$t $(systemctl is-enabled "$t" 2>/dev/null || true)"
    done > "$TIMERS_STATE_FILE"
  fi
  for t in $APT_TIMERS; do
    systemctl disable --now "$t" >/dev/null 2>&1 || true
  done
  systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1 || true
}

restore_host() {
  rm -f "$APT_CONF_FILE" "$NEEDRESTART_FILE"
  if [ -f "$TIMERS_STATE_FILE" ]; then
    while read -r t state; do
      if [ "$state" = "enabled" ]; then
        systemctl enable --now "$t" >/dev/null 2>&1 || warn "could not re-enable $t"
      fi
    done < "$TIMERS_STATE_FILE"
    rm -f "$TIMERS_STATE_FILE"
  fi
}

# Recovers an interrupted dpkg (pod killed in the middle of apt, power cut...).
recover_dpkg() {
  dpkg --configure -a || fail_hard "dpkg --configure -a failed"
  apt_get -f install || fail_hard "apt-get -f install failed"
  audit=$(dpkg --audit 2>&1 || true)
  [ -z "$audit" ] || fail_hard "dpkg --audit reports half-installed packages: $audit"
}

write_pin_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
# Managed by os-upgrade: blocks the kernel metapackages so that the pinned kernel
# ($KERNEL_VERSION) stays the only one. See docs/kernel.md before removing it.
Package: $KERNEL_META_GLOBS
Pin: version *
Pin-Priority: -1
EOF
}

# Removes and blocks the kernel metapackages. Done BEFORE upgrading, so neither the
# full-upgrade nor do-release-upgrade installs (or waits to reboot into) an unwanted kernel.
apply_kernel_policy() {
  for p in $KEEP_MANUAL_PKGS; do
    if pkg_installed "$p"; then apt-mark manual "$p" >/dev/null; fi
  done
  write_pin_file "$PIN_FILE"
  # shellcheck disable=SC2086 # the globs go to dpkg-query, not to the shell
  metas=$(set -f; installed_matching $KERNEL_META_GLOBS)
  if [ -n "$metas" ]; then
    info "Removing kernel metapackages: $(echo "$metas" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    apt_get remove --purge $metas || fail_hard "could not remove the kernel metapackages"
  fi
}

# Links the predownloaded .deb files into the apt cache; apt does not download again what
# is already there with the right hash.
stage_archives() {
  [ -d "$ARCHIVES_DIR" ] || return 0
  mkdir -p "$APT_CACHE_DIR"
  count=0
  for f in "$ARCHIVES_DIR"/*.deb; do
    [ -e "$f" ] || continue
    dest="$APT_CACHE_DIR/$(basename "$f")"
    [ -e "$dest" ] || ln -f "$f" "$dest" 2>/dev/null || cp -f "$f" "$dest"
    count=$((count + 1))
  done
  info "Predownloaded packages available in the apt cache: $count"
}

# Purges image and modules of any kernel other than KERNEL_VERSION. With keep_running=true
# it also keeps the running kernel (it cannot be removed live).
purge_other_kernels() {
  keep_running=$1
  running=$(running_kernel)
  to_purge=""
  for p in $(installed_matching 'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' 'linux-main-modules-zfs-[0-9]*'); do
    v=${p#linux-image-}
    v=${v#linux-main-modules-zfs-}
    v=${v#linux-modules-extra-}
    v=${v#linux-modules-}
    [ "$v" = "$KERNEL_VERSION" ] && continue
    if is_true "$keep_running" && [ "$v" = "$running" ]; then continue; fi
    to_purge="$to_purge $p"
  done
  [ -n "$to_purge" ] || return 0
  info "Purging unwanted kernels:$to_purge"
  # shellcheck disable=SC2086
  apt_get remove --purge --allow-change-held-packages $to_purge \
    || fail_hard "could not purge the kernels:$to_purge"
}

# Sets GRUB_DEFAULT to the exact KERNEL_VERSION entry. Required when another kernel with a
# higher version is left (e.g. the running HWE kernel of the source release).
configure_grub() {
  update-grub >/dev/null 2>&1 || fail_hard "update-grub failed"
  [ -f "$GRUB_CFG" ] || fail_hard "$GRUB_CFG does not exist"
  submenu=$(grep -o "'gnulinux-advanced-[^']*'" "$GRUB_CFG" | head -n1 | tr -d "'")
  entry=$(grep -o "'gnulinux-$KERNEL_VERSION-advanced-[^']*'" "$GRUB_CFG" | head -n1 | tr -d "'")
  if [ -z "$submenu" ] || [ -z "$entry" ]; then
    fail_hard "no GRUB entry for $KERNEL_VERSION in $GRUB_CFG; not rebooting"
  fi
  mkdir -p "$(dirname "$GRUB_DEFAULT_FILE")"
  cat > "$GRUB_DEFAULT_FILE" <<EOF
# Managed by os-upgrade: always boot the pinned kernel. See docs/kernel.md.
GRUB_DEFAULT="$submenu>$entry"
EOF
  update-grub >/dev/null 2>&1 || fail_hard "update-grub failed"
  grep -qF "set default=\"$submenu>$entry\"" "$GRUB_CFG" \
    || fail_hard "grub.cfg did not pick up GRUB_DEFAULT=$submenu>$entry; not rebooting"
  info "GRUB will boot $KERNEL_VERSION by default"
}

# Installs and pins KERNEL_VERSION, removes the rest and points GRUB to it.
ensure_kernel() {
  stage_archives
  info "Installing kernel $KERNEL_VERSION"
  # shellcheck disable=SC2046
  apt_get install --allow-change-held-packages $(kernel_packages) \
    || fail_hard "could not install kernel $KERNEL_VERSION"
  # shellcheck disable=SC2046
  apt-mark hold $(kernel_packages) >/dev/null || fail_hard "apt-mark hold failed"
  apply_kernel_policy
  purge_other_kernels true
  for f in "vmlinuz-$KERNEL_VERSION" "initrd.img-$KERNEL_VERSION"; do
    [ -s "$ROOT/boot/$f" ] || fail_hard "/boot/$f is missing after installing the kernel"
  done
  configure_grub
}

install_host_script() {
  mkdir -p "$(dirname "$HOST_SCRIPT")"
  cp "$SELF" "$HOST_SCRIPT.tmp"
  chmod 0755 "$HOST_SCRIPT.tmp"
  mv "$HOST_SCRIPT.tmp" "$HOST_SCRIPT"
}

wait_for_unit() {
  info "Release upgrade in progress (unit $UNIT). On the node: journalctl -fu $UNIT"
  while unit_active; do sleep 30; done
  [ ! -f "$FAILED_FILE" ] || die "unit $UNIT failed: $(cat "$FAILED_FILE")"
  [ -f "$RELEASE_DONE_FILE" ] \
    || fail_hard "unit $UNIT ended without completing the release upgrade; see journalctl -u $UNIT"
  info "Release upgrade finished; waiting for the reboot"
  sleep infinity
  die "the reboot did not happen"
}

finalize() {
  step "7/7" "verification and finalize: Ubuntu $TARGET_VERSION with kernel $KERNEL_VERSION"
  # Idempotent: also pins the kernel on nodes that were already running it.
  apply_kernel_policy
  purge_other_kernels false
  # shellcheck disable=SC2046
  apt-mark hold $(kernel_packages) >/dev/null
  configure_grub
  apt_get autoremove --purge || warn "autoremove failed (not critical)"
  restore_host
  if [ -f "$ROOT/run/reboot-required" ]; then
    warn "a reboot is pending because of later packages; not rebooting (one reboot per window)"
  fi
  wait_rke2_active
  disabled=$(disabled_sources)
  if [ -n "$disabled" ]; then
    warn "sources disabled by the upgrade (review and re-enable by hand if needed): $(echo "$disabled" | tr '\n' ';')"
  fi
  HOOK_RESULT=""
  run_post_upgrade_hook
  write_report "$disabled"
  rm -rf "$ARCHIVES_DIR" "$ALT_APT_DIR"
  rm -f "$REBOOTS_FILE" "$RELEASE_STARTED_FILE" "$RELEASE_DONE_FILE" "$PREDOWNLOAD_FILE" "$STARTED_AT_FILE"
  printf 'date=%s\nos=%s\nkernel=%s\n' "$(date -Is)" "$(os_version)" "$(running_kernel)" > "$DONE_FILE"
  info "OK: Ubuntu $(os_version), kernel $(running_kernel). Report in ${REPORT_FILE#"$ROOT"}"
}

# Report kept on the node. Only written the first time the node finishes (later Job runs
# on an already finished node do not overwrite it).
write_report() {
  [ ! -f "$DONE_FILE" ] || return 0
  started=$(cat "$STARTED_AT_FILE" 2>/dev/null || true)
  duration="?"
  if [ -n "$started" ]; then
    secs=$(( $(date +%s) - $(date -d "$started" +%s) ))
    duration="$((secs / 60)) min"
  fi
  {
    echo "os-upgrade: report for $(hostname)"
    echo "finished:       $(date -Is)"
    echo "started:        ${started:-?}"
    echo "duration:       $duration"
    echo "system:         Ubuntu $(os_version)"
    echo "kernel:         $(running_kernel) (pinned: $KERNEL_VERSION)"
    echo "reboots:        $(cat "$REBOOTS_FILE" 2>/dev/null || echo 0)"
    echo "hook:           ${HOOK_RESULT:-no hook}"
    echo "sources disabled by the upgrade:"
    if [ -n "$1" ]; then echo "$1" | sed 's/^/  /'; else echo "  none"; fi
    echo "held packages (besides the kernel):"
    held=$(held_packages)
    if [ -n "$held" ]; then echo "$held" | sed 's/^/  /'; else echo "  none"; fi
  } > "$REPORT_FILE"
}

# ------------------------------------------------------------------ alternate apt (predownload)
detect_mirror() {
  if [ -n "$APT_MIRROR" ]; then echo "$APT_MIRROR"; return; fi
  m=""
  if [ -f "$ROOT/etc/apt/sources.list" ]; then
    m=$(grep -E '^deb ' "$ROOT/etc/apt/sources.list" | sed 's/\[[^]]*\]//' \
      | awk '$2 !~ /security/ {print $2; exit}')
  fi
  if [ -z "$m" ] && [ -f "$ROOT/etc/apt/sources.list.d/ubuntu.sources" ]; then
    m=$(awk '/^URIs:/ && $2 !~ /security/ {print $2; exit}' "$ROOT/etc/apt/sources.list.d/ubuntu.sources")
  fi
  if [ -z "$m" ]; then
    case "$(dpkg --print-architecture)" in
      amd64|i386) m="http://archive.ubuntu.com/ubuntu" ;;
      *) m="http://ports.ubuntu.com/ubuntu-ports" ;;
    esac
  fi
  echo "$m"
}

# apt with target release sources and its own state: does not touch the system lists or
# cache. Reads the dpkg status (read only) to work out what is missing.
alt_apt_get() {
  apt-get -y -o DPkg::Lock::Timeout=600 \
    -o Dir::Etc::SourceList="$ALT_APT_DIR/sources.list" \
    -o Dir::Etc::SourceParts="$ALT_APT_DIR/empty" \
    -o Dir::Etc::Preferences="$ALT_APT_DIR/preferences" \
    -o Dir::Etc::PreferencesParts="$ALT_APT_DIR/empty" \
    -o Dir::State::Lists="$ALT_APT_DIR/lists" \
    -o Dir::Cache="$ALT_APT_DIR/cache" \
    -o Dir::Cache::Archives="$ARCHIVES_DIR" \
    "$@"
}

setup_alt_apt() {
  mirror=$1
  arch=$(dpkg --print-architecture)
  mkdir -p "$ALT_APT_DIR/lists/partial" "$ALT_APT_DIR/cache" "$ALT_APT_DIR/empty" "$ARCHIVES_DIR/partial"
  : > "$ALT_APT_DIR/sources.list"
  for suite in "$TARGET_CODENAME" "$TARGET_CODENAME-updates" "$TARGET_CODENAME-security"; do
    echo "deb [arch=$arch] $mirror $suite main restricted universe multiverse" >> "$ALT_APT_DIR/sources.list"
  done
  write_pin_file "$ALT_APT_DIR/preferences"
}

# ------------------------------------------------------------------ subcommands
cmd_prepare() {
  validate_config
  export_proxy_env
  mkdir -p "$STATE_DIR"
  if is_done; then
    info "Node already upgraded; nothing to prepare"
    return 0
  fi
  check_not_failed
  if unit_active || [ -f "$RELEASE_STARTED_FILE" ]; then
    info "Upgrade already in progress on this node; the upgrade container takes over"
    return 0
  fi

  version=$(os_version)
  check_version_supported "$version"
  check_space
  check_hook_syntax
  check_sources
  check_held

  if predownload_matches; then
    info "Predownload present for $KERNEL_VERSION"
  elif is_true "$REQUIRE_PREDOWNLOAD"; then
    die "predownload missing for $KERNEL_VERSION/$TARGET_VERSION; run the os-upgrade-predownload Plan first"
  else
    warn "no predownload: everything will be downloaded during the window"
  fi

  apt-get -o DPkg::Lock::Timeout=600 update >/dev/null \
    || die "apt-get update failed (proxy or mirror unreachable?)"

  if [ "$version" = "$SOURCE_VERSION" ]; then
    pending=$(pending_reboot_pkgs)
    simulated=$(simulated_reboot_pkgs)
    needs=$(printf '%s\n%s\n' "$pending" "$simulated" | sed '/^$/d' | sort -u | tr '\n' ' ')
    if [ -n "$needs" ]; then
      if is_true "$SINGLE_REBOOT"; then
        die "the node would need a prior reboot because of: $needs. Patch and reboot the node in the patching window, or use SINGLE_REBOOT=false"
      fi
      warn "there will be an extra reboot before the release upgrade because of: $needs"
    fi
  fi
  info "Preflight OK: Ubuntu $version, kernel $(running_kernel) -> $TARGET_VERSION + $KERNEL_VERSION"
}

cmd_predownload() {
  validate_config
  export_proxy_env
  mkdir -p "$STATE_DIR"
  if is_done; then
    info "Node already upgraded; nothing to download"
    return 0
  fi
  version=$(os_version)
  check_version_supported "$version"
  check_space
  check_sources
  check_held

  mirror=$(detect_mirror)
  info "Predownloading $TARGET_VERSION ($TARGET_CODENAME) and kernel $KERNEL_VERSION from $mirror"
  setup_alt_apt "$mirror"
  rm -f "$PREDOWNLOAD_FILE"
  alt_apt_get update || die "apt-get update for $TARGET_CODENAME failed (proxy or mirror unreachable?)"

  # Kernel: mandatory and exact, without resolving dependencies.
  # shellcheck disable=SC2046
  ( cd "$ARCHIVES_DIR" && alt_apt_get download $(kernel_packages) ) \
    || die "could not download kernel $KERNEL_VERSION; is it published in $mirror $TARGET_CODENAME-updates?"

  # Rest of the system: best effort. Anything missing is downloaded during the window.
  if [ "$version" = "$SOURCE_VERSION" ]; then
    if ! alt_apt_get --download-only full-upgrade >/dev/null; then
      warn "the full $TARGET_CODENAME predownload failed; only the kernel is available"
    fi
  fi
  rm -rf "$ARCHIVES_DIR/partial"/*

  count=$(find "$ARCHIVES_DIR" -maxdepth 1 -name '*.deb' | wc -l)
  size=$(du -sm "$ARCHIVES_DIR" | awk '{print $1}')
  printf 'KERNEL_VERSION=%s\nTARGET_VERSION=%s\nDATE=%s\nPACKAGES=%s\n' \
    "$KERNEL_VERSION" "$TARGET_VERSION" "$(date -Is)" "$count" > "$PREDOWNLOAD_FILE"
  info "Predownload OK: $count packages, $size MB in $ARCHIVES_DIR"

  if [ "$version" = "$SOURCE_VERSION" ]; then
    apt-get -o DPkg::Lock::Timeout=600 update >/dev/null || warn "apt-get update for $SOURCE_VERSION failed"
    needs=$(printf '%s\n%s\n' "$(pending_reboot_pkgs)" "$(simulated_reboot_pkgs)" | sed '/^$/d' | sort -u | tr '\n' ' ')
    if [ -n "$needs" ]; then
      warn "this node will need patching + a prior reboot to have a single reboot in the window: $needs"
    fi
  fi
}

cmd_upgrade() {
  validate_config
  export_proxy_env
  mkdir -p "$STATE_DIR"
  write_config
  # Start of a new process (also a kernel change on a node upgraded earlier).
  if [ ! -f "$STARTED_AT_FILE" ] && ! is_done; then
    date -Is > "$STARTED_AT_FILE"
    rm -f "$DONE_FILE"
  fi
  info "State: Ubuntu $(os_version), kernel $(running_kernel); target $TARGET_VERSION + $KERNEL_VERSION"

  if is_done; then
    finalize
    return 0
  fi
  check_not_failed
  if unit_active; then wait_for_unit; fi
  if release_upgrade_interrupted; then
    fail_hard "the release upgrade started and did not finish (power cut or reboot halfway?); check /var/log/dist-upgrade/ and journalctl -u $UNIT"
  fi

  case "$(os_version)" in
    "$SOURCE_VERSION")
      step "1/7" "prepare the host (apt, needrestart, unattended-upgrades timers)"
      check_space
      configure_host
      recover_dpkg
      step "2/7" "remove kernel metapackages and pin $KERNEL_VERSION"
      apply_kernel_policy
      step "3/7" "bring $SOURCE_VERSION to the latest patch level"
      apt-get -o DPkg::Lock::Timeout=600 update || die "apt-get update failed"
      apt_get full-upgrade || die "apt-get full-upgrade failed"
      apt_get install update-manager-core || die "could not install update-manager-core"
      needs=$(pending_reboot_pkgs | tr '\n' ' ')
      if [ -n "$needs" ]; then
        warn "do-release-upgrade requires a reboot first because of: $needs"
        reboot_now "reboot before the release upgrade"
      fi
      step "4/7" "release upgrade to $TARGET_VERSION in the host unit $UNIT"
      install_host_script
      systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
      systemd-run --unit="$UNIT" --description="os-upgrade: Ubuntu $SOURCE_VERSION -> $TARGET_VERSION" \
        "$HOST_SCRIPT_PATH" host-phase || die "systemd-run failed"
      wait_for_unit
      ;;
    "$TARGET_VERSION")
      # Already on the target release but not running the pinned kernel: a node that was
      # already there (kernel change only) or GRUB booted another kernel.
      step "1/7" "prepare the host"
      configure_host
      recover_dpkg
      step "5/7" "install and pin kernel $KERNEL_VERSION and GRUB"
      ensure_kernel
      step "6/7" "reboot"
      reboot_now "boot kernel $KERNEL_VERSION"
      ;;
    *)
      fail_hard "unexpected release: $(os_version)"
      ;;
  esac
}

cmd_host_phase() {
  load_config
  export_proxy_env
  [ ! -f "$FAILED_FILE" ] || exit 1
  stage_archives
  date -Is > "$RELEASE_STARTED_FILE"
  third_party=""
  if is_true "$ALLOW_THIRD_PARTY"; then third_party="--allow-third-party"; fi
  info "do-release-upgrade to $TARGET_VERSION ${third_party:-(without --allow-third-party)}"
  # shellcheck disable=SC2086 # third_party is one option or nothing
  do-release-upgrade -f DistUpgradeViewNonInteractive $third_party \
    || fail_hard "do-release-upgrade ended with an error; see /var/log/dist-upgrade/"
  version=$(os_version)
  [ "$version" = "$TARGET_VERSION" ] || fail_hard "after do-release-upgrade the release is $version"
  # From here on a failure is no longer an interrupted release upgrade: the retry takes the
  # target release branch (install kernel + GRUB + reboot).
  date -Is > "$RELEASE_DONE_FILE"
  recover_dpkg
  step "5/7" "install and pin kernel $KERNEL_VERSION and GRUB"
  ensure_kernel
  step "6/7" "reboot"
  reboot_now "boot $TARGET_VERSION with kernel $KERNEL_VERSION"
}

cmd_status() {
  echo "Ubuntu:          $(os_version)"
  echo "Running kernel:  $(running_kernel)"
  if [ -f "$CONFIG_FILE" ]; then
    echo "Target kernel:   $(sed -n "s/^KERNEL_VERSION='\(.*\)'$/\1/p" "$CONFIG_FILE")"
  fi
  echo "Unit $UNIT: $(systemctl is-active "$UNIT" 2>/dev/null || true)"
  for f in "$PREDOWNLOAD_FILE" "$RELEASE_STARTED_FILE" "$RELEASE_DONE_FILE" "$DONE_FILE" "$REBOOTS_FILE" "$FAILED_FILE"; do
    [ -f "$f" ] && echo "$(basename "$f"): $(tr '\n' ' ' < "$f")"
  done
  if [ -f "$GRUB_DEFAULT_FILE" ]; then grep '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; fi
  if [ -f "$REPORT_FILE" ]; then echo; cat "$REPORT_FILE"; fi
  return 0
}

cmd_reset_failed() {
  if [ -f "$FAILED_FILE" ]; then
    echo "Clearing failure mark: $(cat "$FAILED_FILE")"
  fi
  rm -f "$FAILED_FILE" "$REBOOTS_FILE"
  echo "Done. The next Job attempt will resume from the current state."
}

main() {
  case "$PHASE" in
    prepare) cmd_prepare ;;
    predownload) cmd_predownload ;;
    upgrade) cmd_upgrade ;;
    host-phase) cmd_host_phase ;;
    status) cmd_status ;;
    reset-failed) cmd_reset_failed ;;
    *)
      echo "Usage: $0 {prepare|predownload|upgrade|host-phase|status|reset-failed}" >&2
      exit 2
      ;;
  esac
}

main
