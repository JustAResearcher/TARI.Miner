$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'tari-c29-launcher-test-' + [Guid]::NewGuid().ToString('N')
)

function New-TestRoot {
    param([string]$Name)
    $caseRoot = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $caseRoot 'bin') -Force |
        Out-Null
    Copy-Item (Join-Path $root 'start-c29.ps1') $caseRoot
    @'
@echo off
echo 0, 12.0, Test GPU 0
echo 1, 8.9, Test GPU 1
'@ | Set-Content -LiteralPath (Join-Path $caseRoot 'nvidia-smi.cmd') -Encoding Ascii
    return $caseRoot
}

function Invoke-Launcher {
    param([string]$CaseRoot)
    $env:TARI_WALLET = 'test-login'
    $env:TARI_NVIDIA_SMI = Join-Path $CaseRoot 'nvidia-smi.cmd'
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $CaseRoot 'start-c29.ps1') 2>&1
    return [pscustomobject]@{
        Code = $LASTEXITCODE
        Output = ($output -join [Environment]::NewLine)
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $workerSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class LauncherTestWorker {
    public static int Main(string[] args) {
        string name = Path.GetFileNameWithoutExtension(
            Process.GetCurrentProcess().MainModule.FileName
        );
        string arch = name.EndsWith("sm_120", StringComparison.OrdinalIgnoreCase)
            ? "SM120"
            : "SM89";
        Thread.Sleep(Int32.Parse(
            Environment.GetEnvironmentVariable("TARI_TEST_" + arch + "_DELAY")
        ));
        return Int32.Parse(
            Environment.GetEnvironmentVariable("TARI_TEST_" + arch + "_CODE")
        );
    }
}
'@
    $worker = Join-Path $tempRoot 'worker.exe'
    Add-Type -TypeDefinition $workerSource -OutputAssembly $worker `
        -OutputType ConsoleApplication

    $missingRoot = New-TestRoot 'missing'
    Copy-Item $worker (
        Join-Path $missingRoot 'bin\tari_c29_pool_miner_sm_120.exe'
    )
    $env:TARI_TEST_SM120_DELAY = '20'
    $env:TARI_TEST_SM120_CODE = '0'
    $missing = Invoke-Launcher $missingRoot
    if ($missing.Code -ne 5) {
        throw "Expected missing backend exit 5, got $($missing.Code).`n$($missing.Output)"
    }

    $orderRoot = New-TestRoot 'failure-order'
    Copy-Item $worker (
        Join-Path $orderRoot 'bin\tari_c29_pool_miner_sm_120.exe'
    )
    Copy-Item $worker (
        Join-Path $orderRoot 'bin\tari_c29_pool_miner_sm_89.exe'
    )
    $env:TARI_TEST_SM120_DELAY = '500'
    $env:TARI_TEST_SM120_CODE = '5'
    $env:TARI_TEST_SM89_DELAY = '100'
    $env:TARI_TEST_SM89_CODE = '4'
    $ordered = Invoke-Launcher $orderRoot
    if ($ordered.Code -ne 4) {
        throw "Expected earliest worker exit 4, got $($ordered.Code).`n$($ordered.Output)"
    }

    Write-Host 'PowerShell launcher regressions passed'
    $global:LASTEXITCODE = 0
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
