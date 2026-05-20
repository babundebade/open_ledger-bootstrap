# Open Ledger — installer bootstrap

This repository contains only the two bootstrap scripts (`get.sh`, `get.ps1`) that
download and run the [Open Ledger](https://github.com/babundebade/open_ledger)
installer. The application source itself lives in a private repository and is
distributed as container images on `ghcr.io`.

## Install

You will need:

- Docker (or Podman) installed and running.
- An Open Ledger **license key** — a classic GitHub Personal Access Token with
  the `read:packages` scope, issued to you by the project author.

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.ps1 | iex
```

You will be prompted for your license key (input is hidden).

## Update / uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash -s -- --update
curl -fsSL https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.sh | bash -s -- --uninstall
```

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
