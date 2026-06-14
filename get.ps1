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
    if ($_.Exception.Response.StatusCode.value__ -ne 401) {
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
$env:OPEN_LEDGER_INSTALL_DIR_HOST = $InstallDir
# Forward-slash form used inside the Linux container to translate host paths.
$env:OPEN_LEDGER_WIN_INSTALL_DIR = $InstallDir.Replace("\", "/")
docker run -it --rm `
    -e OPEN_LEDGER_LICENSE `
    -e OPEN_LEDGER_CHANNEL `
    -e OPEN_LEDGER_INSTALL_DIR_HOST `
    -e OPEN_LEDGER_WIN_INSTALL_DIR `
    -v "${InstallDir}:/host" `
    -v "/var/run/docker.sock:/var/run/docker.sock" `
    "${InstallerImage}:${Channel}" --install-dir /host @args
$_dockerExitCode = $LASTEXITCODE

# Post-install: register Windows Task Scheduler task and stamp update-agent.json.
# Skip for --update and --uninstall runs (those are handled by the installer container).
$_isUpdate    = $args -contains "--update"
$_isUninstall = $args -contains "--uninstall"

# Uninstall: remove the scheduled task even if the installer container exited non-zero,
# so a partially-failed uninstall does not leave the update agent running.
if ($_isUninstall) {
    $taskName = "OpenLedger-UpdateAgent"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Info "Removing scheduled update agent task ..."
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Info "Update agent task removed."
    }
}

if ($_dockerExitCode -ne 0) { exit $_dockerExitCode }

if (-not $_isUpdate -and -not $_isUninstall) {
    # Read state_root and env_file from install-state.json written by the wizard.
    $stateFile = Join-Path $InstallDir "install-state.json"
    $stateRoot = $null
    $envFile   = $null
    if (Test-Path $stateFile) {
        try {
            $s = Get-Content $stateFile -Raw | ConvertFrom-Json
            $stateRoot = $s.answers.state_root
            $envFile   = $s.answers.env_file
        } catch {}
    }
    if (-not $stateRoot) { $stateRoot = Join-Path $InstallDir "state" }
    if (-not $envFile)   { $envFile   = Join-Path $stateRoot "env\open_ledger.env" }

    # Register Task Scheduler task from the XML the installer rendered.
    $taskXml  = Join-Path $stateRoot "open-ledger-update-agent-task.xml"
    $taskName = "OpenLedger-UpdateAgent"
    if (Test-Path $taskXml) {
        Info "Registering update agent scheduled task ..."
        try {
            $xmlContent  = Get-Content $taskXml -Raw
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            Register-ScheduledTask -TaskName $taskName -Xml $xmlContent -User $currentUser -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Info "Update agent registered. It will run every 12 hours and at each boot."
        } catch {
            Info "Warning: could not register scheduled task: $_"
            Info "  To register manually, run: Register-ScheduledTask -TaskName '$taskName' -Xml (Get-Content '$taskXml' -Raw) -Force"
        }
    } else {
        Info "Warning: task XML not found at $taskXml — update agent not registered."
    }

    # Stamp update-agent.json so the backend knows the agent is active on this host.
    $controlDir = Join-Path $stateRoot "control"
    New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
    @{
        mode        = "task-scheduler"
        install_dir = $InstallDir
        state_root  = $stateRoot
        env_file    = $envFile
    } | ConvertTo-Json | Set-Content (Join-Path $controlDir "update-agent.json") -Encoding UTF8

    Info ""
    Info "Open Ledger is ready. Management commands:"
    Info "  Update:    `$env:OPEN_LEDGER_DIR=`"$InstallDir`"; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.ps1'))) -- --update"
    Info "  Uninstall: `$env:OPEN_LEDGER_DIR=`"$InstallDir`"; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/babundebade/open_ledger-bootstrap/main/get.ps1'))) -- --uninstall"
}
