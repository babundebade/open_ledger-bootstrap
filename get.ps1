# open_ledger one-command installer (Windows).
#
# Normal use:
#   irm https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.ps1 | iex
#
# Environment overrides:
#   OPEN_LEDGER_LICENSE         license key (GitHub PAT; classic with 'read:packages',
#                                or fine-grained with Account -> Packages: Read)
#   OPEN_LEDGER_LICENSE_FILE    path to a file containing the license key
#   OPEN_LEDGER_CHANNEL         release channel (default: stable)
#   OPEN_LEDGER_DIR             install directory (default: $HOME\open_ledger)
$ErrorActionPreference = "Stop"

$GhcrUser = "babundebade"
$InstallerImage = "ghcr.io/$GhcrUser/open_ledger-installer"
$Channel = if ($env:OPEN_LEDGER_CHANNEL) { $env:OPEN_LEDGER_CHANNEL } else { "stable" }
$InstallDir = if ($env:OPEN_LEDGER_DIR) { $env:OPEN_LEDGER_DIR } else { "$HOME\open_ledger" }

function Fail($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Blue }

# 1. Docker Desktop.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "Docker Desktop is required. Install it: https://www.docker.com/products/docker-desktop/"
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop is installed but not running. Start it from the Start menu and re-run." }

# 2. Registry reachability.
try {
    Invoke-WebRequest -Uri "https://ghcr.io/v2/" -Method Head -TimeoutSec 10 -UseBasicParsing *> $null
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -ne 401 -and $code -ne 405) {
        Fail "Could not reach ghcr.io. Check your internet connection or proxy settings."
    }
}

# 3. License key (read securely from the console).
$License = $env:OPEN_LEDGER_LICENSE
if (-not $License -and $env:OPEN_LEDGER_LICENSE_FILE) {
    $License = (Get-Content $env:OPEN_LEDGER_LICENSE_FILE -Raw).Trim()
}
if (-not $License) {
    $secure = Read-Host "Enter your Open Ledger license key" -AsSecureString
    $License = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if (-not $License) { Fail "A license key is required." }

# 4. Registry login. docker's stderr surfaces so the customer sees the real cause.
Info "Authenticating with the image registry ..."
$License | docker login ghcr.io -u $GhcrUser --password-stdin *> $null
if ($LASTEXITCODE -ne 0) {
    Fail @"
Registry login failed.
Common causes:
  - the license key is mistyped or expired
  - the token is missing GHCR read permission. Either:
      * Classic PAT: enable the 'read:packages' scope, or
      * Fine-grained PAT: under 'Account permissions' (not
        'Repository permissions'), enable 'Packages: Read'.
See the docker output above for the exact reason.
"@
}

# 5. Run the installer container.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Info "Pulling the installer image ..."
# No output suppression: docker pull's progress is the only feedback on a slow link.
docker pull "${InstallerImage}:${Channel}"
if ($LASTEXITCODE -ne 0) {
    Fail @"
Could not pull ${InstallerImage}:${Channel}.
The login above succeeded, but the registry refused the pull.
'docker login' validates only that the token is well-formed - it does not
check whether the token can read packages. The token you used is almost
certainly missing GHCR read permission:
  - Classic PAT: enable the 'read:packages' scope.
  - Fine-grained PAT: under 'Account permissions' (not 'Repository
    permissions'), enable 'Packages: Read'.
Regenerate the token with the right permission and re-run.
"@
}
Info "Starting the guided installer ..."
# Set the key in this process's environment and pass `-e OPEN_LEDGER_LICENSE`
# by name only, so the value is never part of the docker argv.
$env:OPEN_LEDGER_LICENSE = $License
$env:OPEN_LEDGER_CHANNEL = $Channel
docker run -it --rm `
    -e OPEN_LEDGER_LICENSE `
    -e OPEN_LEDGER_CHANNEL `
    -v "${InstallDir}:/host" `
    -v "/var/run/docker.sock:/var/run/docker.sock" `
    "${InstallerImage}:${Channel}" --install-dir /host @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
