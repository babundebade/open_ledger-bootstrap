#!/usr/bin/env bash
# open_ledger one-command installer (Linux/macOS).
#
# Normal use:
#   curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash
#
# Update or uninstall an existing deployment:
#   curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash -s -- --update
#   curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash -s -- --uninstall
#
# Environment overrides:
#   OPEN_LEDGER_LICENSE         license key (GitHub PAT; classic with 'read:packages',
#                                or fine-grained with Account → Packages: Read)
#   OPEN_LEDGER_LICENSE_FILE    path to a file containing the license key
#   OPEN_LEDGER_CHANNEL         release channel (default: stable)
#   OPEN_LEDGER_DIR             install directory (default: $HOME/open_ledger)
set -euo pipefail

GHCR_USER="babundebade"
INSTALLER_IMAGE="ghcr.io/${GHCR_USER}/open_ledger-installer"
CHANNEL="${OPEN_LEDGER_CHANNEL:-stable}"
INSTALL_DIR="${OPEN_LEDGER_DIR:-${HOME}/open_ledger}"

err() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }

# Detect the host container engine. Echoes "docker" or "podman".
detect_engine() {
  if command -v docker >/dev/null 2>&1; then
    echo "docker"; return 0
  fi
  if command -v podman >/dev/null 2>&1; then
    echo "podman"; return 0
  fi
  err "Docker or Podman is required. Install Docker: https://docs.docker.com/engine/install/"
}

# Engine-not-running hint tailored to the host OS.
engine_start_hint() {
  local engine="$1"
  if [ "$(uname)" = "Darwin" ]; then
    echo "Start Docker Desktop (or 'podman machine start') and re-run."
  elif [ "$(id -u)" -eq 0 ]; then
    echo "Start the daemon with: systemctl start ${engine}"
  else
    echo "Start the daemon with: sudo systemctl start ${engine}"
  fi
}

# Path of Podman's Docker-compatible API socket (may not be live yet).
podman_socket_path() {
  podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null | sed 's#^unix://##'
}

# True when Podman's API socket is live.
podman_socket_live() {
  [ "$(podman info --format '{{.Host.RemoteSocket.Exists}}' 2>/dev/null)" = "true" ]
}

# Bring up Podman's API socket. On Linux via systemd socket activation; on
# macOS by starting the Podman machine. Polls briefly for the socket to come
# up. Returns non-zero if it cannot be started; the caller surfaces the
# underlying error message.
ensure_podman_socket() {
  if podman_socket_live; then return 0; fi
  local start_err=""
  if [ "$(uname)" = "Darwin" ]; then
    start_err=$(podman machine start 2>&1 >/dev/null) || { echo "$start_err" >&2; return 1; }
  elif [ "$(id -u)" -eq 0 ]; then
    start_err=$(systemctl enable --now podman.socket 2>&1 >/dev/null) \
      || { echo "$start_err" >&2; return 1; }
  else
    start_err=$(systemctl --user enable --now podman.socket 2>&1 >/dev/null) \
      || { echo "$start_err" >&2; return 1; }
  fi
  local i=0
  while [ "$i" -lt 10 ]; do
    podman_socket_live && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Echo the host socket to bind into the installer container for ENGINE.
resolve_engine_socket() {
  local engine="$1"
  if [ "$engine" = "docker" ]; then
    echo "/var/run/docker.sock"; return 0
  fi
  if ! ensure_podman_socket; then
    local cmd="systemctl --user enable --now podman.socket"
    if [ "$(uname)" = "Darwin" ]; then
      cmd="podman machine start"
    elif [ "$(id -u)" -eq 0 ]; then
      cmd="systemctl enable --now podman.socket"
    fi
    err "Podman's API socket is not available and could not be started automatically.
       See the message above for the underlying error.
       Run:  ${cmd}
       Then re-run this installer."
  fi
  local sock
  sock="$(podman_socket_path)"
  [ -n "$sock" ] || err "Could not determine Podman's API socket path."
  echo "$sock"
}

# Quick reachability check for the image registry. Catches corporate proxies
# and offline hosts before we hit a confusing 'login failed' later.
preflight_registry() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /dev/null --max-time 10 "https://ghcr.io/v2/" 2>/dev/null && return 0
    # ghcr.io/v2/ returns 401 when reachable; -f treats that as failure, so
    # also accept a plain HTTP response.
    curl -sSL -o /dev/null --max-time 10 "https://ghcr.io/v2/" 2>/dev/null && return 0
  fi
  return 1
}

main() {
  local engine
  engine="$(detect_engine)"
  if ! "$engine" info >/dev/null 2>&1; then
    err "$engine is installed but not running.
       $(engine_start_hint "$engine")"
  fi

  if ! preflight_registry; then
    err "Could not reach ghcr.io. Check your internet connection or proxy settings."
  fi

  # License key (read from the terminal, never echoed).
  local license="${OPEN_LEDGER_LICENSE:-}"
  if [ -z "$license" ] && [ -n "${OPEN_LEDGER_LICENSE_FILE:-}" ]; then
    license="$(tr -d '[:space:]' < "$OPEN_LEDGER_LICENSE_FILE")"
  fi
  if [ -z "$license" ]; then
    printf 'Enter your Open Ledger license key: ' > /dev/tty
    read -rs license < /dev/tty
    printf '\n' > /dev/tty
  fi
  [ -n "$license" ] || err "A license key is required."

  # Registry login. We let docker/podman's own stderr surface so the customer
  # sees the actual reason on failure (bad token, wrong scope, etc.).
  info "Authenticating with the image registry ..."
  if ! printf '%s' "$license" | "$engine" login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null; then
    err "Registry login failed.
       Common causes:
         - the license key is mistyped or expired
         - the token is missing GHCR read permission. Either:
             * Classic PAT: enable the 'read:packages' scope, or
             * Fine-grained PAT: under 'Account permissions' (not
               'Repository permissions'), enable 'Packages: Read'.
       See the engine output above for the exact reason."
  fi

  # Resolve the host engine socket to bind into the installer container.
  local socket
  socket="$(resolve_engine_socket "$engine")"

  # Run the installer container.
  mkdir -p "$INSTALL_DIR"
  info "Pulling the installer image ..."
  # No output suppression: docker pull's progress bar is the only feedback
  # during what can be a multi-hundred-MB download on a slow link.
  if ! "$engine" pull "${INSTALLER_IMAGE}:${CHANNEL}"; then
    err "Could not pull ${INSTALLER_IMAGE}:${CHANNEL}.
       The login above succeeded, but the registry refused the pull.
       'docker login' validates only that the token is well-formed — it does
       not check whether the token can read packages. The token you used is
       almost certainly missing GHCR read permission:
         - Classic PAT: enable the 'read:packages' scope.
         - Fine-grained PAT: under 'Account permissions' (not
           'Repository permissions'), enable 'Packages: Read'.
       Regenerate the token with the right permission and re-run."
  fi
  info "Starting the guided installer ..."
  # Export the key and pass `-e OPEN_LEDGER_LICENSE` by name only, so the value
  # lands in the container's env block and never appears in this process's argv.
  export OPEN_LEDGER_LICENSE="$license"
  export OPEN_LEDGER_CHANNEL="$CHANNEL"
  exec "$engine" run -it --rm \
    -e OPEN_LEDGER_LICENSE \
    -e OPEN_LEDGER_CHANNEL \
    -v "${INSTALL_DIR}:/host" \
    -v "${socket}:/var/run/docker.sock" \
    "${INSTALLER_IMAGE}:${CHANNEL}" --install-dir /host "$@"
}

# Run main unless sourced by a test with execution suppressed.
if [ -z "${OPEN_LEDGER_GETSH_NOEXEC:-}" ]; then
  main "$@"
fi
