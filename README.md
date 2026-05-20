# Open Ledger — installer bootstrap

**Open Ledger** is a self-hosted personal finance application with bank
synchronisation (FinTS/DKB), ML-powered transaction categorisation, multi-household
support, and a dashboard UI. The application itself is distributed as private
container images on `ghcr.io`; this repository hosts only the public bootstrap
scripts (`get.sh`, `get.ps1`) that install it on your machine.

## System requirements

| Item | Value |
|---|---|
| Operating system | Linux, macOS, or Windows 10 / 11 |
| Container engine | Docker 20+ or Podman 4+ |
| Free disk space | 2 GiB minimum (enforced by the installer) |
| RAM | 1 GiB free recommended |
| Network | outbound HTTPS access to `ghcr.io` |

## Install

You will need:

- **Docker (or Podman) installed and running.** If you don't already have it:
  - Linux — <https://docs.docker.com/engine/install/>
  - macOS — <https://www.docker.com/products/docker-desktop/>
  - Windows — <https://www.docker.com/products/docker-desktop/>
  - Or Podman — <https://podman.io/docs/installation>
- **An Open Ledger license key** — a GitHub Personal Access Token with
  permission to read packages, issued to you by the project author. Either:
  - a *classic* PAT with the **`read:packages`** scope, **or**
  - a *fine-grained* PAT with **Account permissions → Packages: Read**
    (not under Repository permissions — that's a common mistake that lets
    `docker login` succeed but causes the pull to fail with `denied`).

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.ps1 | iex
```

You will be prompted for your license key (input is hidden).

## What the wizard will ask you

The installer is interactive. Expect these questions:

1. **Existing install?** — shown only if a previous deployment is detected; offers
   *update*, *reconfigure*, *uninstall*, or *cancel*.
2. **Where should Open Ledger run?** — choose `local` (this device, browser at
   `http://localhost:10000`) or `remote` (a server reachable from other devices).
3. **Access mode** *(remote only)* — choose `caddy` (Caddy reverse proxy with
   automatic TLS — free Let's Encrypt certificate when you give it a domain,
   self-signed otherwise) or `http` (plain HTTP on port 10000; bring your own
   reverse proxy if you need TLS).
4. **Domain / hostname** *(remote only)* — the domain for `caddy`, or the server
   IP/hostname for `http`.
5. **Data location** — directory under which the database, env file, logs, and
   backups live (default: `~/open_ledger`).
6. **FinTS** — whether to enable bank synchronisation. If yes, asks for a FinTS
   *product ID* and *version*; these come from registering with your bank's FinTS
   programme — decline if you haven't done that yet, you can enable it later via
   *Settings* → *Reconfigure*.

**Single-user home install?** Pick **local**, accept the default data location,
decline FinTS. The whole wizard takes under a minute on a warm machine.

## After install

When the wizard completes you'll see a line like:

```
Open Ledger is installed. Open: http://localhost:10000
```

1. Open the printed URL in your browser.
2. Click **Register** — the first account created becomes the household **admin**.
3. Sign in. Import your first transactions via the **Imports** tab (CSV) or set
   up a bank in **Bank Accounts** (FinTS).

## Update / uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash -s -- --update
curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash -s -- --uninstall
```

Updates snapshot the SQLite database to `<data-location>/backups/` before pulling
new images. Uninstall asks whether to keep or permanently delete your data.

## Keeping your license key handy

Re-typing the key on every update is awkward. Save it to a file and point
`OPEN_LEDGER_LICENSE_FILE` at it:

```bash
mkdir -p ~/.config/open_ledger
chmod 700 ~/.config/open_ledger
printf '%s' 'ghp_yourtokenhere' > ~/.config/open_ledger/license
chmod 600 ~/.config/open_ledger/license
export OPEN_LEDGER_LICENSE_FILE=~/.config/open_ledger/license
```

## Environment overrides

| Variable | Purpose | Default |
|----------|---------|---------|
| `OPEN_LEDGER_LICENSE` | License key (PAT) | — |
| `OPEN_LEDGER_LICENSE_FILE` | Path to a file containing the key | — |
| `OPEN_LEDGER_CHANNEL` | Release channel | `stable` |
| `OPEN_LEDGER_DIR` | Install directory | `~/open_ledger` |

## What these scripts do

1. Verify Docker (or Podman) is installed and running.
2. Verify `ghcr.io` is reachable.
3. Prompt for the license key (silent input).
4. Log Docker in to `ghcr.io` with the key.
5. Pull and run the installer image, which then guides you through the rest.

The scripts do not write the license key to disk and pass it to the installer
container via an environment variable, never via the command line.

## Troubleshooting

**`<engine> is installed but not running.`**
Start your container engine and re-run the one-liner.
- Linux: `sudo systemctl start docker` (or `start podman`)
- macOS / Windows: open Docker Desktop from the Applications / Start menu

**`Registry login failed.`** *or* **`Could not pull … denied`**
Your license key was rejected by `ghcr.io`. Note that `docker login` only
validates the token is well-formed — it does *not* check whether the token
can read packages, so a token with the wrong permission will pass login and
then fail on `docker pull` with `denied`. Either symptom means the token is
missing GHCR read permission:
- **Classic PAT** — enable the **`read:packages`** scope.
- **Fine-grained PAT** — under **Account permissions** (not Repository
  permissions), enable **Packages: Read**.

Mistyped or expired keys produce the same error; regenerate if in doubt, or
contact the project author for a new key.

**`The application did not become healthy after the update.`**
First boot on slow hardware (e.g. a Raspberry Pi) can exceed the 90-second
health-check window. Re-run the one-liner with `--update` to retry. If the
problem persists, inspect logs:

```bash
docker compose -f ~/open_ledger/docker-compose.app.yml logs
```

Your pre-update database snapshot is in `~/open_ledger/backups/`, so updates are
safe to re-attempt.

**`Could not reach ghcr.io.`**
Check your internet connection. If you're behind a corporate proxy, configure
Docker to use it (see <https://docs.docker.com/engine/cli/proxy/>) and re-run.
