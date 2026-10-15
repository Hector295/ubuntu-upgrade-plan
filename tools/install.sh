#!/bin/sh
# Descarga las herramientas de desarrollo en versiones fijas a tools/bin,
# verificando su sha256. Idempotente: si la versión ya está instalada, no hace nada.
# Solo linux/amd64.
set -eu

TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="$TOOLS_DIR/bin"
GH=https://github.com

# nombre|versión|url|sha256
TOOLS="
shellcheck|0.10.0|$GH/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz|6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87
bats|1.11.1|$GH/bats-core/bats-core/archive/refs/tags/v1.11.1.tar.gz|5c57ed9616b78f7fd8c553b9bae3c7c9870119edd727ec17dbd1185c599f79d9
kubeconform|0.6.7|$GH/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz|95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73
kustomize|5.4.3|$GH/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz|3669470b454d865c8184d6bce78df05e977c9aea31c30df3c669317d43bcc7a7
yq|4.44.3|$GH/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64|a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7
"

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "Solo soportado en Linux x86_64" >&2; exit 1; }

install_tool() {
  name=$1 version=$2 url=$3 sum=$4
  stamp="$BIN_DIR/.$name-$version"
  [ -f "$stamp" ] && return 0

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  echo ">>> $name $version"
  curl -fsSL -o "$work/download" "$url"
  echo "$sum  $work/download" | sha256sum -c --quiet - \
    || { echo "sha256 incorrecto para $name" >&2; exit 1; }

  case "$name" in
    shellcheck)
      tar -xJf "$work/download" -C "$work"
      install -m 0755 "$work/shellcheck-v$version/shellcheck" "$BIN_DIR/shellcheck" ;;
    bats)
      tar -xzf "$work/download" -C "$work"
      rm -rf "$TOOLS_DIR/bats-core"
      mv "$work/bats-core-$version" "$TOOLS_DIR/bats-core"
      ln -sf ../bats-core/bin/bats "$BIN_DIR/bats" ;;
    kubeconform|kustomize)
      tar -xzf "$work/download" -C "$work"
      install -m 0755 "$work/$name" "$BIN_DIR/$name" ;;
    yq)
      install -m 0755 "$work/download" "$BIN_DIR/yq" ;;
  esac

  rm -f "$BIN_DIR/.$name-"*
  touch "$stamp"
  rm -rf "$work"
  trap - EXIT
}

mkdir -p "$BIN_DIR"
echo "$TOOLS" | while IFS='|' read -r name version url sum; do
  [ -n "$name" ] || continue
  install_tool "$name" "$version" "$url" "$sum"
done
echo "Herramientas listas en $BIN_DIR"
