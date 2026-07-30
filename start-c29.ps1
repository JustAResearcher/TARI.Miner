# Windows launcher for the Tari C29 miner.
#
# Detects every NVIDIA GPU, selects the backend matching each card, and runs one
# worker per GPU. Workers are stopped when this script is interrupted, which is
# why this is PowerShell rather than batch: a batch file cannot run cleanup after
# Ctrl+C, so backgrounded workers survived it and had to be ended by hand.
#
# start-c29.bat calls this script, so the documented entry point is unchanged.

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

$pool           = Get-EnvOrDefault 'TARI_POOL' 'taric29-ca.luckypool.io:3111'
$workerName     = Get-EnvOrDefault 'TARI_WORKER' $env:COMPUTERNAME
$devices        = Get-EnvOrDefault 'TARI_DEVICES' 'all'
$nvidiaSmi      = Get-EnvOrDefault 'TARI_NVIDIA_SMI' 'nvidia-smi'
$logDir         = Get-EnvOrDefault 'TARI_LOG_DIR' ''
$loginSeparator = Get-EnvOrDefault 'TARI_LOGIN_SEPARATOR' ''
$wallet         = Get-EnvOrDefault 'TARI_WALLET' ''
$dryRun         = (Get-EnvOrDefault 'TARI_DRY_RUN' '0') -eq '1'
$minerArgs      = @($args)

if ([string]::IsNullOrEmpty($wallet)) {
    # Only prompt when there is a console to prompt at. Started by another
    # process, a prompt would wait for input that never arrives, so fail with
    # the same message and exit code the Linux starter uses.
    if ([Console]::IsInputRedirected) {
        Write-Host 'ERROR: Set TARI_WALLET to your Tari wallet address.'
        exit 2
    }
    Write-Host 'TARI.Miner C29 - community miner with no developer fee'
    Write-Host "Pool: $pool"
    $wallet = Read-Host 'Enter your Tari wallet address'
}
if ([string]::IsNullOrEmpty($wallet)) {
    Write-Host 'ERROR: A wallet address is required.'
    exit 2
}

$gpuOutput = & $nvidiaSmi --query-gpu=index,compute_cap,name --format=csv,noheader,nounits 2>$null
if ($LASTEXITCODE -ne 0 -or $null -eq $gpuOutput) {
    Write-Host 'ERROR: nvidia-smi could not enumerate NVIDIA GPUs.'
    exit 3
}

$archForCap = @{ '8.6' = 'sm_86'; '8.9' = 'sm_89'; '12.0' = 'sm_120' }
$requested = @()
if ($devices -ne 'all') {
    $requested = @($devices -split ',' | ForEach-Object { $_.Trim() })
}

$detected = 0
$missing = 0
$plan = @()

foreach ($line in @($gpuOutput)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = $line -split ',', 3
    if ($fields.Count -lt 3) { continue }
    $index = $fields[0].Trim()
    $cap   = $fields[1].Trim()
    $name  = $fields[2].Trim()
    $detected++

    if ($devices -ne 'all' -and $requested -notcontains $index) { continue }

    $arch = $archForCap[$cap]
    if ([string]::IsNullOrEmpty($arch)) {
        Write-Host "WARNING: Skipping GPU $index [$name]: compute capability $cap is not supported."
        continue
    }

    $backend = Join-Path $root "bin\tari_c29_pool_miner_$arch.exe"
    if (-not (Test-Path -LiteralPath $backend)) {
        Write-Host "ERROR: Missing $arch backend for GPU ${index}: $backend"
        $missing++
        continue
    }

    $gpuWorker = "$workerName-gpu$index"
    Write-Host "GPU $index [$name] compute $cap -> $arch, worker $gpuWorker"

    $workerArgs = @()
    $workerArgs += $minerArgs
    $workerArgs += '--device', $index, '--pool', $pool, '--wallet', $wallet, '--worker', $gpuWorker
    if (-not [string]::IsNullOrEmpty($loginSeparator)) {
        $workerArgs += '--login-separator', $loginSeparator
    }

    $plan += [pscustomobject]@{ Index = $index; Backend = $backend; Args = $workerArgs }
}

if ($detected -eq 0) {
    Write-Host 'ERROR: No NVIDIA GPUs were detected.'
    exit 3
}
if ($plan.Count -eq 0) {
    Write-Host "ERROR: No supported GPUs matched TARI_DEVICES=$devices."
    exit 4
}

if ($dryRun) {
    foreach ($item in $plan) {
        Write-Host "[DRY RUN] `"$($item.Backend)`" $($item.Args -join ' ')"
    }
    Write-Host "Started $($plan.Count) miner worker(s) from $detected detected NVIDIA GPU(s)."
    if ($missing -gt 0) { exit 5 }
    exit 0
}

if (-not [string]::IsNullOrEmpty($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$workers = @()
$workerFailed = $false
$workerExitCode = 0
try {
    foreach ($item in $plan) {
        $startArgs = @{
            FilePath     = $item.Backend
            ArgumentList = $item.Args
            NoNewWindow  = $true
            PassThru     = $true
            WorkingDirectory = $root
            ErrorAction  = 'Stop'
        }
        if (-not [string]::IsNullOrEmpty($logDir)) {
            # Start-Process cannot send both streams to one file, so progress and
            # diagnostics are split. Tools read the progress log; the speed report,
            # which carries hashrate and share counts, is written to stdout.
            $startArgs.RedirectStandardOutput = Join-Path $logDir "gpu$($item.Index).log"
            $startArgs.RedirectStandardError  = Join-Path $logDir "gpu$($item.Index).err.log"
        }
        $process = Start-Process @startArgs
        # Windows PowerShell 5.1 only retains the native process handle after it
        # has been accessed. Keep it so ExitCode remains available after exit.
        [void]$process.Handle
        $workers += $process
    }

    Write-Host "Started $($workers.Count) miner worker(s) from $detected detected NVIDIA GPU(s)."
    if (-not [string]::IsNullOrEmpty($logDir)) {
        Write-Host "Worker output: $logDir\gpu<index>.log and gpu<index>.err.log"
    }
    Write-Host 'Press Ctrl+C to stop all GPU workers.'

    # A worker exits non-zero only for something a restart must clear: a
    # repeatedly rejected login (4), a failed solver (5), an unresponsive pool
    # (6). Stop the survivors and surface that code, so a rig supervisor sees the
    # failure instead of a launcher still babysitting its healthy GPUs.
    while ($true) {
        $exited = @($workers | Where-Object { $_.HasExited })
        foreach ($worker in $exited) {
            if ($worker.ExitCode -ne 0 -and $workerExitCode -eq 0) {
                Write-Host "ERROR: Miner worker PID $($worker.Id) exited with code $($worker.ExitCode)."
                $workerExitCode = $worker.ExitCode
                $workerFailed = $true
            }
        }
        if ($workerFailed) {
            $alive = @($workers | Where-Object { -not $_.HasExited })
            if ($alive.Count -gt 0) {
                Write-Host "Stopping $($alive.Count) remaining GPU worker(s)."
            }
            break
        }
        if ($exited.Count -eq $workers.Count) {
            Write-Host 'All GPU workers have exited.'
            break
        }
        Start-Sleep -Seconds 2
    }
}
catch {
    Write-Host "ERROR: Failed to start miner worker: $($_.Exception.Message)"
    $workerFailed = $true
}
finally {
    # Runs on Ctrl+C as well as normal completion, so no worker is left behind.
    foreach ($worker in $workers) {
        if (-not $worker.HasExited) {
            Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($workerFailed) {
    if ($workerExitCode -ne 0) { exit $workerExitCode }
    exit 1
}
if ($missing -gt 0) { exit 5 }
exit 0
