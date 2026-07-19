param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Version) {
    $VersionHeader = Get-Content -Raw (Join-Path $Root 'version.h')
    if ($VersionHeader -notmatch 'TARI_MINER_VERSION\s+"([^"]+)"') {
        throw 'Could not read the miner version from version.h.'
    }
    $Version = $Matches[1]
}

$Dist = Join-Path $Root 'dist'
$StageRoot = Join-Path $Dist "staging\v$Version"
$ReleaseRoot = Join-Path $Dist 'release'
$RootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
$StageFull = [IO.Path]::GetFullPath($StageRoot)
if (-not $StageFull.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to stage outside the repository: $StageFull"
}

if (Test-Path -LiteralPath $StageRoot) {
    Remove-Item -LiteralPath $StageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $StageRoot, $ReleaseRoot | Out-Null

$Packages = @(
    @{
        Name = "TARI.Miner-v$Version-windows"
        Readme = 'packaging\README.txt'
        Starter = 'start-c29.bat'
        Suffix = '.exe'
    },
    @{
        Name = "TARI.Miner-v$Version-linux"
        Readme = 'packaging\README-LINUX.txt'
        Starter = 'start-c29.sh'
        Suffix = ''
    }
)
$Architectures = @('sm_86', 'sm_89', 'sm_120')

foreach ($Package in $Packages) {
    $Stage = Join-Path $StageRoot $Package.Name
    $StageBin = Join-Path $Stage 'bin'
    New-Item -ItemType Directory -Force -Path $StageBin | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root $Package.Readme) -Destination (Join-Path $Stage 'README.txt')
    Copy-Item -LiteralPath (Join-Path $Root $Package.Starter) -Destination $Stage
    Copy-Item -LiteralPath (Join-Path $Root 'LICENSE') -Destination $Stage
    Copy-Item -LiteralPath (Join-Path $Root 'THIRD_PARTY_NOTICES.md') -Destination $Stage

    foreach ($Arch in $Architectures) {
        foreach ($Program in @('tari_c29_pool_miner', 'tari_c29_solver')) {
            $Binary = Join-Path $Root "bin\${Program}_${Arch}$($Package.Suffix)"
            if (-not (Test-Path -LiteralPath $Binary)) {
                throw "Missing release binary: $Binary"
            }
            Copy-Item -LiteralPath $Binary -Destination $StageBin
        }
    }
}

$WindowsArchive = Join-Path $ReleaseRoot "TARI.Miner-v$Version-windows.zip"
$LinuxArchive = Join-Path $ReleaseRoot "TARI.Miner-v$Version-linux.tar.gz"
Remove-Item -LiteralPath $WindowsArchive, $LinuxArchive -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $StageRoot "TARI.Miner-v$Version-windows\*") -DestinationPath $WindowsArchive -CompressionLevel Optimal
& tar.exe -czf $LinuxArchive -C (Join-Path $StageRoot "TARI.Miner-v$Version-linux") .
if ($LASTEXITCODE -ne 0) {
    throw 'tar failed while creating the Linux package.'
}

$Archives = @($WindowsArchive, $LinuxArchive)
$Checksums = foreach ($Archive in $Archives) {
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
    "$Hash  $(Split-Path -Leaf $Archive)"
}
$ChecksumsPath = Join-Path $ReleaseRoot 'SHA256SUMS.txt'
$Checksums | Set-Content -LiteralPath $ChecksumsPath -Encoding ascii

$ReleaseNotes = @'
# TARI.Miner C29 v{0}

Download one package for your operating system. Both packages automatically
detect every supported NVIDIA GPU and choose the matching RTX 30, RTX 40, or
RTX 50 backend for each card, including mixed-card rigs.

## Windows

1. Download and extract `TARI.Miner-v{0}-windows.zip`.
2. Run `start-c29.bat`.
3. Enter your Tari wallet address.

## Linux

1. Download and extract `TARI.Miner-v{0}-linux.tar.gz`.
2. Run `chmod +x start-c29.sh bin/tari_c29_*`.
3. Run `./start-c29.sh` and enter your Tari wallet address.

The pool is prefilled as `taric29-ca.luckypool.io:3111`. There is no developer
fee, and the launcher does not change GPU power, clock, voltage, or fan settings.
'@ -f $Version
$ReleaseNotes | Set-Content -LiteralPath (Join-Path $ReleaseRoot 'RELEASE_NOTES.md') -Encoding utf8

Write-Host "Release packages created in $ReleaseRoot"
$Checksums | ForEach-Object { Write-Host $_ }
