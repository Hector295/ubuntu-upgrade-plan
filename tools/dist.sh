#!/bin/sh
# Builds the release tarball: the operator tool without tests or lab, with the pinned yq,
# kustomize and kubeconform from tools/bin (run tools/install.sh first). kubectl is not
# included: the operator's one is used (the image does include it).
#
# Usage: dist.sh <version> [<output-dir>]
#   <output-dir>/os-upgrade/                              unpacked tree (the image copies it)
#   <output-dir>/os-upgrade-<version>-linux-amd64.tar.gz  + .sha256
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${1:-}" ] || { echo "Usage: $0 <version> [<output-dir>]" >&2; exit 2; }
VERSION=$1
OUT_DIR=${2:-$REPO_DIR/dist}
NAME="os-upgrade-$VERSION-linux-amd64"
TREE="$OUT_DIR/os-upgrade"

for tool in yq kustomize kubeconform; do
  [ -x "$REPO_DIR/tools/bin/$tool" ] || { echo "tools/bin/$tool not found; run 'make tools'" >&2; exit 1; }
done

rm -rf "$TREE" "$OUT_DIR/$NAME.tar.gz" "$OUT_DIR/$NAME.tar.gz.sha256"
mkdir -p "$TREE/bin" "$TREE/tools/bin" "$TREE/manifests/overlays" "$TREE/docs"

cd "$REPO_DIR"
cp bin/os-upgrade "$TREE/bin/"
cp -R scripts "$TREE/"
cp -R manifests/base manifests/components "$TREE/manifests/"
# Template for os-upgrade init.
cp -R manifests/overlays/lab "$TREE/manifests/overlays/"
cp -R docs/* "$TREE/docs/"
cp README.md "$TREE/"
for tool in yq kustomize kubeconform; do
  cp "tools/bin/$tool" "$TREE/tools/bin/"
done
echo "$VERSION" > "$TREE/VERSION"
chmod 0755 "$TREE/bin/os-upgrade" "$TREE"/scripts/*.sh

# Reproducible: fixed order, owner and dates (the ones of the last commit).
mtime=$(git log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
tar -C "$OUT_DIR" --sort=name --owner=0 --group=0 --numeric-owner --mtime="$mtime" \
  --transform "s,^os-upgrade,$NAME," -cf - os-upgrade | gzip -n > "$OUT_DIR/$NAME.tar.gz"
(cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "Generated $OUT_DIR/$NAME.tar.gz"
