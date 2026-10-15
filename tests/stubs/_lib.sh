# Common stub helpers. State lives in $STUB_STATE, the fake root in $ROOT.
# shellcheck shell=sh
record() { echo "$*" >> "$STUB_STATE/calls.log"; }
fail_if() { if [ -f "$STUB_STATE/fail.$1" ]; then exit 1; fi; }
installed() { grep -qx "$1" "$STUB_STATE/installed" 2>/dev/null; }
held() { grep -qx "$1" "$STUB_STATE/held" 2>/dev/null; }
add_installed() { installed "$1" || echo "$1" >> "$STUB_STATE/installed"; }
del_installed() {
  grep -vx "$1" "$STUB_STATE/installed" > "$STUB_STATE/installed.tmp" || true
  mv "$STUB_STATE/installed.tmp" "$STUB_STATE/installed"
}
