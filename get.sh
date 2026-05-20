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
#   OPEN_LEDGER_DEBUG           when set to 1, enables 'set -x' trace output
set -euo pipefail

# Identifier so we can tell from the user's terminal log whether they ran a
# version of this script that contains a given fix. Bump on every change.
BOOTSTRAP_REV="2026-05-20-d"

if [ "${OPEN_LEDGER_DEBUG:-0}" = "1" ]; then
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

GHCR_USER="babundebade"
INSTALLER_IMAGE="ghcr.io/${GHCR_USER}/open_ledger-installer"
CHANNEL="${OPEN_LEDGER_CHANNEL:-stable}"
INSTALL_DIR="${OPEN_LEDGER_DIR:-${HOME}/open_ledger}"

err() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }

# Detect the host container engine. Echoes "docker" or "podman".
#
# If `docker` is the `podman-docker` shim (a wrapper that re-invokes podman),
# prefer real podman so we resolve podman's socket path instead of the
# nonexistent /var/run/docker.sock that the shim would have us bind.
detect_engine() {
  if command -v docker >/dev/null 2>&1; then
    if docker --version 2>/dev/null | grep -qi podman; then
      if command -v podman >/dev/null 2>&1; then
        echo "podman"; return 0
      fi
    fi
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

# True when Podman's API socket file is actually present on disk. We can't
# trust `podman info`'s RemoteSocket.Exists field — it sometimes reports the
# expected path as live when the systemd user unit isn't actually running.
podman_socket_live() {
  local sock
  sock="$(podman_socket_path)"
  [ -n "$sock" ] && [ -S "$sock" ]
}

# Try to bring up Podman's API socket via the platform's native mechanism
# (podman machine on macOS, systemd socket activation on Linux). Stderr from
# the activation command is surfaced to the caller for diagnostics. Returns
# non-zero if the socket still isn't live afterward.
try_native_podman_socket() {
  # Capture the activation command's combined stdout+stderr so we can surface
  # the real failure reason. The previous form `2>&1 >/dev/null` applied the
  # redirections in the wrong order and produced an empty string.
  local start_err=""
  if [ "$(uname)" = "Darwin" ]; then
    start_err=$(podman machine start 2>&1) || { echo "$start_err" >&2; return 1; }
  elif [ "$(id -u)" -eq 0 ]; then
    start_err=$(systemctl enable --now podman.socket 2>&1) \
      || { echo "$start_err" >&2; return 1; }
  else
    start_err=$(systemctl --user enable --now podman.socket 2>&1) \
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

# Launch `podman system service` ourselves on a known path. This is the
# fallback when systemd user-session activation can't reach the unit — e.g.
# on a host without an active user systemd session (common over SSH without
# `loginctl enable-linger`). The service stays up for the life of the bind
# mount because we don't pass `--time`, and it gets cleaned up when the host
# is rebooted; for repeat installs we kill any leftover before relaunching.
PODMAN_FALLBACK_SOCK=""
PODMAN_FALLBACK_LOG=""
start_fallback_podman_socket() {
  # Prefer XDG_RUNTIME_DIR but fall back to /tmp if it's unset or not writable
  # (rootless podman under sudo, restricted runtimes, etc.).
  local runtime="${XDG_RUNTIME_DIR:-}"
  if [ -z "$runtime" ] || ! [ -w "$runtime" ]; then
    runtime="/tmp"
  fi
  mkdir -p "$runtime" 2>/dev/null || true
  PODMAN_FALLBACK_SOCK="${runtime}/open_ledger-podman.sock"
  PODMAN_FALLBACK_LOG="${runtime}/open_ledger-podman-service.log"
  rm -f "$PODMAN_FALLBACK_SOCK"
  : > "$PODMAN_FALLBACK_LOG" 2>/dev/null || true
  # Run detached so the installer container can keep talking to it after
  # this script `exec`s into `podman run`. Capture stdout/stderr to a log so
  # we can show the user why it failed if the socket never appears.
  setsid podman system service --time=0 "unix://${PODMAN_FALLBACK_SOCK}" \
    >"$PODMAN_FALLBACK_LOG" 2>&1 < /dev/null &
  disown 2>/dev/null || true
  local i=0
  while [ "$i" -lt 15 ]; do
    if [ -S "$PODMAN_FALLBACK_SOCK" ]; then
      echo "$PODMAN_FALLBACK_SOCK"; return 0
    fi
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
  if podman_socket_live; then
    podman_socket_path; return 0
  fi
  if try_native_podman_socket && podman_socket_live; then
    podman_socket_path; return 0
  fi
  # Native activation didn't materialize a socket on disk. Spin up our own.
  local sock
  if sock="$(start_fallback_podman_socket)" && [ -n "$sock" ]; then
    echo "$sock"; return 0
  fi
  local cmd="systemctl --user enable --now podman.socket"
  if [ "$(uname)" = "Darwin" ]; then
    cmd="podman machine start"
  elif [ "$(id -u)" -eq 0 ]; then
    cmd="systemctl enable --now podman.socket"
  fi
  local svc_log_tail=""
  if [ -n "${PODMAN_FALLBACK_LOG:-}" ] && [ -s "$PODMAN_FALLBACK_LOG" ]; then
    svc_log_tail=$(tail -n 5 "$PODMAN_FALLBACK_LOG" 2>/dev/null | sed 's/^/         /')
  fi
  err "Could not bring up Podman's API socket.
       Tried platform activation and a fallback 'podman system service'.
       See messages above for the underlying error.${svc_log_tail:+
       Last lines from 'podman system service':
${svc_log_tail}}
       You can try:  ${cmd}
       (over SSH, also run:  loginctl enable-linger \$USER)
       Then re-run this installer."
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
  info "Open Ledger bootstrap rev: ${BOOTSTRAP_REV}"
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
  # Redirect stdin from /dev/tty so prompts inside the container reach the
  # user's terminal even when this script was invoked via `curl ... | bash`
  # (where our own stdin is the closed curl pipe — podman warns "The input
  # device is not a TTY" and every prompt hangs).
  exec "$engine" run -it --rm \
    -e OPEN_LEDGER_LICENSE \
    -e OPEN_LEDGER_CHANNEL \
    -v "${INSTALL_DIR}:/host" \
    -v "${socket}:/var/run/docker.sock" \
    "${INSTALLER_IMAGE}:${CHANNEL}" --install-dir /host "$@" </dev/tty
}

# Run main unless sourced by a test with execution suppressed.
if [ -z "${OPEN_LEDGER_GETSH_NOEXEC:-}" ]; then
  main "$@"
fi
