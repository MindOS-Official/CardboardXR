param(
    [string]$UnityExe = "",
    [string]$BundleId = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$VersionFile = Join-Path $RepoRoot "ProjectSettings\ProjectVersion.txt"
$ExpectedVersion = "6000.6.8f1"

if (Test-Path $VersionFile) {
    $line = Get-Content $VersionFile | Where-Object { $_ -like "m_EditorVersion:*" } | Select-Object -First 1
    if ($line -match "m_EditorVersion:\s*(\S+)") {
        $ExpectedVersion = $Matches[1]
    }
}

if ([string]::IsNullOrWhiteSpace($UnityExe)) {
    $candidates = @(
        "C:\Program Files\Unity\Hub\Editor\$ExpectedVersion\Editor\Unity.exe",
        "D:\Program Files\Unity\Hub\Editor\$ExpectedVersion\Editor\Unity.exe",
        "$env:LOCALAPPDATA\Programs\Unity\Hub\Editor\$ExpectedVersion\Editor\Unity.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $UnityExe = $c
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($UnityExe) -or -not (Test-Path $UnityExe)) {
    Write-Error "Unity $ExpectedVersion not found. Install Unity $ExpectedVersion with iOS Build Support or pass -UnityExe 'C:\path\to\Unity.exe'."
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($BundleId)) {
    $env:CARDBOARDXR_BUNDLE_ID = $BundleId.Trim()
}

New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "Logs") | Out-Null
$LogFile = Join-Path $RepoRoot "Logs\ios_export.log"

Write-Host "Running Unity $ExpectedVersion iOS export (ProjectBootstrap.StereoBuilder.BuildIos)..."
$proc = Start-Process -FilePath $UnityExe -ArgumentList @(
    "-batchmode",
    "-quit",
    "-projectPath", "`"$RepoRoot`"",
    "-buildTarget", "iOS",
    "-executeMethod", "ProjectBootstrap.StereoBuilder.BuildIos",
    "-logFile", "`"$LogFile`""
) -Wait -PassThru

if ($proc.ExitCode -ne 0) {
    Write-Error "Unity iOS export failed with exit code $($proc.ExitCode). Inspect $LogFile."
    exit $proc.ExitCode
}

$XcodeProj = Join-Path $RepoRoot "Builds\iOS\Unity-iPhone.xcodeproj"
if (-not (Test-Path $XcodeProj)) {
    Write-Error "Expected Xcode project missing at $XcodeProj."
    exit 1
}

Write-Host "Xcode project exported to $RepoRoot\Builds\iOS"
Write-Host "If pushing to GitHub for Direct Xcode Mode (without UNITY_LICENSE secrets), run: git add -f Builds/iOS"
