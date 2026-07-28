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

function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Blue }
# Failures throw instead of `exit`: under `irm | iex` this script runs in the
# user's own session, and `exit` would close their console before they can
# read the error. The top-level catch below prints the message and, only when
# the script was run as a file (CI, local checkout), exits with code 1.
function Fail($msg) { throw $msg }

function Install-OpenLedger([string[]]$ScriptArgs = @()) {
    $GhcrUser = "babundebade"
    $InstallerImage = "ghcr.io/$GhcrUser/open_ledger-installer"
    $Channel = if ($env:OPEN_LEDGER_CHANNEL) { $env:OPEN_LEDGER_CHANNEL } else { "stable" }
    $InstallDir = if ($env:OPEN_LEDGER_DIR) { $env:OPEN_LEDGER_DIR } else { "$HOME\open_ledger" }

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

    # 4. Registry login. Only stdout is suppressed — docker's stderr must surface
    # so the customer sees the real cause on failure.
    Info "Authenticating with the image registry ..."
    $License | docker login ghcr.io -u $GhcrUser --password-stdin | Out-Null
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
        "${InstallerImage}:${Channel}" --install-dir /host @ScriptArgs
    $dockerExitCode = $LASTEXITCODE

    # Post-install: register Windows Task Scheduler task and stamp update-agent.json.
    # Skip for --update and --uninstall runs (those are handled by the installer container).
    $isUpdate    = $ScriptArgs -contains "--update"
    $isUninstall = $ScriptArgs -contains "--uninstall"

    # Uninstall: remove the scheduled task even if the installer container exited non-zero,
    # so a partially-failed uninstall does not leave the update agent running.
    if ($isUninstall) {
        $taskName = "OpenLedger-UpdateAgent"
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Info "Removing scheduled update agent task ..."
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Info "Update agent task removed."
        }
    }

    if ($dockerExitCode -ne 0) {
        Fail "The installer exited with code ${dockerExitCode}. See its output above for the reason; re-run this command to resume."
    }

    if (-not $isUpdate -and -not $isUninstall) {
        # Read state_root and env_file from install-state.json written by the wizard.
        $stateFile = Join-Path $InstallDir "install-state.json"
        $stateRoot = $null
        $envFile   = $null
        if (Test-Path $stateFile) {
            try {
                $s = Get-Content $stateFile -Raw | ConvertFrom-Json
                $stateRoot = $s.answers.state_root
                $envFile   = $s.answers.env_file
            } catch {
                Info "Warning: could not parse ${stateFile}: $($_.Exception.Message) — using default locations."
            }
        }
        if (-not $stateRoot) { $stateRoot = Join-Path $InstallDir "state" }
        if (-not $envFile)   { $envFile   = Join-Path $stateRoot "env\open_ledger.env" }

        # Register Task Scheduler task from the XML the installer rendered.
        # Register-ScheduledTask always needs an elevated token to write into the
        # Task Scheduler root library, regardless of the task's own RunLevel/LogonType
        # (those only govern the task at run time, not at registration time). This
        # script runs in the user's normal, non-elevated session, so the registration
        # is delegated to a short-lived elevated child process (one UAC prompt) instead
        # of running the whole installer elevated.
        $taskXml  = Join-Path $stateRoot "open-ledger-update-agent-task.xml"
        $taskName = "OpenLedger-UpdateAgent"
        if (Test-Path $taskXml) {
            Info "Registering update agent scheduled task (an administrator approval prompt will appear) ..."
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $manualCmd = "Register-ScheduledTask -TaskName '$taskName' -Xml (Get-Content '$taskXml' -Raw) -User '$currentUser' -Force"
            $escTaskXml  = $taskXml.Replace("'", "''")
            $escTaskName = $taskName.Replace("'", "''")
            $escUser     = $currentUser.Replace("'", "''")
            $registerScript = @"
`$ErrorActionPreference = 'Stop'
try {
    `$xmlContent = Get-Content '$escTaskXml' -Raw
    Register-ScheduledTask -TaskName '$escTaskName' -Xml `$xmlContent -User '$escUser' -Force | Out-Null
    Start-ScheduledTask -TaskName '$escTaskName'
    exit 0
} catch {
    exit 1
}
"@
            $registerScriptPath = Join-Path $env:TEMP "open-ledger-register-task-$PID.ps1"
            Set-Content -Path $registerScriptPath -Value $registerScript -Encoding UTF8
            try {
                $proc = Start-Process powershell.exe -ArgumentList @(
                    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $registerScriptPath
                ) -Verb RunAs -Wait -PassThru
                if ($proc.ExitCode -eq 0) {
                    Info "Update agent registered. It will run every 12 hours and at each boot."
                } else {
                    Info "Warning: could not register scheduled task (exit code $($proc.ExitCode))."
                    Info "  To register manually in an elevated PowerShell, run: $manualCmd"
                }
            } catch {
                Info "Warning: could not launch elevated registration: $_"
                Info "  To register manually in an elevated PowerShell, run: $manualCmd"
            } finally {
                Remove-Item $registerScriptPath -ErrorAction SilentlyContinue
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
}

try {
    Install-OpenLedger -ScriptArgs $args
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    # Run as a file (CI, local checkout): propagate a real exit code.
    # Run via `irm | iex`: fall through so the user's session stays open.
    if ($PSCommandPath) { exit 1 }
}
