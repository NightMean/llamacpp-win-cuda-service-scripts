param(
    [string]$TargetBuild = $null
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "llama-common.ps1")

$BaseDir = Get-LlamaProjectRoot -ScriptsDir $PSScriptRoot
$CurrentLink = Join-Path $BaseDir "llama-current"
$ScriptsDir = Join-Path $BaseDir "llama-scripts"
$StopScript = Join-Path $ScriptsDir "stop-llamacpp-server.ps1"
$StartScript = Join-Path $ScriptsDir "start-llamacpp-server.ps1"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "       llama.cpp Build Rollback Tool        " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# Find current target
$CurrentTarget = $null
if (Test-Path $CurrentLink) {
    $Item = Get-Item $CurrentLink -Force
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $CurrentTarget = if ($Item.Target -is [array]) { $Item.Target[0] } else { $Item.Target }
    }
}

Write-Host "Current active directory: $(if ($CurrentTarget) { $CurrentTarget } else { 'None' })"

# Enumerate installed builds
$InstalledDirs = Get-ChildItem -Path $BaseDir -Directory |
    Where-Object { $_.Name -match "^llama-b\d+-bin-win-" -and (Test-Path (Join-Path $_.FullName "llama-server.exe")) } |
    Sort-Object { Get-LlamaCudaBuildNumber -Name $_.Name } -Descending

if (-not $InstalledDirs -or $InstalledDirs.Count -eq 0) {
    throw "No installed llama.cpp build directories found in $BaseDir"
}

# Determine candidate builds to roll back to (excluding currently active target)
$Candidates = @($InstalledDirs | Where-Object { 
    if (-not $CurrentTarget) { return $true }
    [System.IO.Path]::GetFullPath($_.FullName.TrimEnd('\')) -ne [System.IO.Path]::GetFullPath($CurrentTarget.TrimEnd('\'))
})

if ($Candidates.Count -eq 0) {
    Write-Warning "Only one build is currently installed ($($InstalledDirs[0].Name)). No previous build available to roll back to."
    exit 0
}

$SelectedDir = $null
if ($TargetBuild) {
    $SelectedDir = $Candidates | Where-Object { $_.Name -like "*$TargetBuild*" } | Select-Object -First 1
    if (-not $SelectedDir) {
        throw "Specified build '$TargetBuild' not found among available rollback builds."
    }
}
else {
    $SelectedDir = $Candidates[0]
}

Write-Host ""
Write-Host "Target rollback build: $($SelectedDir.Name)" -ForegroundColor Yellow
Write-Host "Path: $($SelectedDir.FullName)"

# Stop server if running
if (Test-Path $StopScript) {
    Write-Host "Stopping running llama-server..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopScript
}

# Re-point junction
if (Test-Path $CurrentLink) {
    Remove-Item $CurrentLink -Force -Recurse -Confirm:$false
}

Write-Host "Switching llama-current junction -> $($SelectedDir.FullName)" -ForegroundColor Green
New-Item -ItemType Junction -Path $CurrentLink -Target $SelectedDir.FullName | Out-Null

# Restart server
if (Test-Path $StartScript) {
    Write-Host "Starting rolled back server..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript
}

Write-Host ""
Write-Host "[+] Rollback complete! Active build is now: $($SelectedDir.Name)" -ForegroundColor Green
