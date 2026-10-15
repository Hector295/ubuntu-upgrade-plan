# shellcheck shell=sh
# Utilidades comunes de los scripts que corren en el equipo del operador
# (preflight.sh, rollout.sh, check-cluster.sh). No se usan en los nodos.

LIB_DIR=$(cd "$(dirname "$0")/lib" && pwd)
REPO_DIR=$(cd "$LIB_DIR/../.." && pwd)
YQ="${YQ:-$REPO_DIR/tools/bin/yq}"
KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-cattle-system}"

ASSUME_YES="${ASSUME_YES:-false}"
DRY_RUN="${DRY_RUN:-false}"
# Origen de las respuestas interactivas (los tests lo sustituyen por un archivo).
CONFIRM_TTY="${CONFIRM_TTY:-/dev/tty}"

ts() { date '+%H:%M:%S'; }
info() { echo "$(ts) $*"; }
warn() { echo "$(ts) AVISO: $*" >&2; }
err() { echo "$(ts) ERROR: $*" >&2; }
die() {
  err "$@"
  exit 1
}

require_tools() {
  command -v "$KUBECTL" >/dev/null 2>&1 || die "no se encuentra kubectl"
  [ -x "$YQ" ] || die "no se encuentra $YQ; ejecutar 'make tools'"
}

# yq sobre JSON leído de stdin, con salida en texto plano.
jq_() { "$YQ" -p json -o yaml "$@"; }

is_true() { [ "$1" = "true" ]; }

# Duración "90s", "30m", "2h" o segundos -> segundos.
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

# Fecha RFC3339 de Kubernetes -> epoch.
to_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

# Las respuestas se leen siempre del descriptor 3, abierto una sola vez por el script
# principal (open_answers): así cada pregunta consume la siguiente línea, también desde
# subshells.
open_answers() {
  # Se prueba antes en un subshell: si exec falla al redirigir, sh termina el script.
  if ( exec 3< "$CONFIRM_TTY" ) 2>/dev/null; then
    exec 3< "$CONFIRM_TTY"
  else
    exec 3< /dev/null
  fi
}

# Pregunta sí/no. Con --yes responde sí sin preguntar.
confirm() {
  if is_true "$ASSUME_YES"; then return 0; fi
  printf '%s [s/N] ' "$1" >&2
  read -r answer <&3 || answer=""
  case "$answer" in s|S|si|SI|sí|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# Pregunta con opciones de una letra; con --yes devuelve la opción por defecto.
ask_choice() {
  prompt=$1
  default=$2
  if is_true "$ASSUME_YES"; then echo "$default"; return; fi
  printf '%s ' "$prompt" >&2
  read -r answer <&3 || answer=""
  echo "${answer:-$default}"
}

# Ejecuta una acción que cambia el cluster; en --dry-run solo la muestra.
mutate() {
  if is_true "$DRY_RUN"; then
    # A stderr: los llamadores suelen descartar la salida normal de la acción.
    if [ "$1" = k ]; then shift; echo "$(ts) [dry-run] kubectl $*" >&2; else echo "$(ts) [dry-run] $*" >&2; fi
    return 0
  fi
  "$@"
}
