# shellcheck shell=sh
# Shared helpers for the scripts that run on the operator's machine
# (preflight.sh, rollout.sh, check-cluster.sh). Not used on the nodes.

LIB_DIR=$(cd "$(dirname "$0")/lib" && pwd)
REPO_DIR=$(cd "$LIB_DIR/../.." && pwd)
YQ="${YQ:-$REPO_DIR/tools/bin/yq}"
KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-cattle-system}"

ASSUME_YES="${ASSUME_YES:-false}"
DRY_RUN="${DRY_RUN:-false}"
# Source of interactive answers (tests replace it with a file).
CONFIRM_TTY="${CONFIRM_TTY:-/dev/tty}"

ts() { date '+%H:%M:%S'; }
info() { echo "$(ts) $*"; }
warn() { echo "$(ts) WARNING: $*" >&2; }
err() { echo "$(ts) ERROR: $*" >&2; }
die() {
  err "$@"
  exit 1
}

require_tools() {
  command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found"
  [ -x "$YQ" ] || die "$YQ not found; run 'make tools'"
}

# yq over JSON read from stdin, with plain-text output.
jq_() { "$YQ" -p json -o yaml "$@"; }

is_true() { [ "$1" = "true" ]; }

# Duration "90s", "30m", "2h" or plain seconds -> seconds.
to_seconds() {
  case "$1" in
    *[!0-9smh]*|'') return 1 ;;
    *s) echo "${1%s}" ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *) echo "$1" ;;
  esac
}

now() { date +%s; }

# Kubernetes RFC3339 date -> epoch.
to_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

# Answers are always read from file descriptor 3, opened once by the main script
# (open_answers): each prompt consumes the next line, also from subshells.
open_answers() {
  # Try in a subshell first: if exec fails to redirect, sh aborts the whole script.
  if ( exec 3< "$CONFIRM_TTY" ) 2>/dev/null; then
    exec 3< "$CONFIRM_TTY"
  else
    exec 3< /dev/null
  fi
}

# Yes/no question. With --yes it answers yes without asking.
confirm() {
  if is_true "$ASSUME_YES"; then return 0; fi
  printf '%s [y/N] ' "$1" >&2
  read -r answer <&3 || answer=""
  # s/si are still accepted for backward compatibility.
  case "$answer" in y|Y|yes|YES|s|S|si|SI) return 0 ;; *) return 1 ;; esac
}

# One-letter choice question; with --yes it returns the default option.
ask_choice() {
  prompt=$1
  default=$2
  if is_true "$ASSUME_YES"; then echo "$default"; return; fi
  printf '%s ' "$prompt" >&2
  read -r answer <&3 || answer=""
  echo "${answer:-$default}"
}

# Runs an action that changes the cluster; with --dry-run it only prints it.
mutate() {
  if is_true "$DRY_RUN"; then
    # To stderr: callers usually discard the action's normal output.
    if [ "$1" = k ]; then shift; echo "$(ts) [dry-run] kubectl $*" >&2; else echo "$(ts) [dry-run] $*" >&2; fi
    return 0
  fi
  "$@"
}
