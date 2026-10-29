param(
    [ValidateRange(1, 99)]
    [int]$CudaMajor = 13
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "llama-common.ps1")

$BaseDir = Get-LlamaProjectRoot -ScriptsDir $PSScriptRoot
$CurrentLink = Join-Path $BaseDir "llama-current"
$GitHubApi = "https://api.github.com/repos/ggml-org/llama.cpp/releases"
$Headers = New-LlamaGitHubHeaders -BaseDir $BaseDir -UserAgent "llamacpp-version-check"

Write-Host "Checking running llama-server..."
$Running = Get-CimInstance Win32_Process |
Where-Object { $_.Name -ieq "llama-server.exe" } |
Select-Object ProcessId, ExecutablePath, CommandLine

if ($Running) {
    $Running | Format-List
}
else {
    Write-Host "llama-server is not running."
}

Write-Host ""
Write-Host "Checking llama-current target..."
if (Test-Path $CurrentLink) {
    $CurrentItem = Get-Item $CurrentLink -Force
    $CurrentTarget = $CurrentItem.Target
    Write-Host "llama-current -> $CurrentTarget"
}
else {
    Write-Host "llama-current does not exist."
    $CurrentTarget = $null
}

Write-Host ""
Write-Host "Checking local release..."
$LocalReleaseFile = Join-Path $CurrentLink ".llamacpp-release"

if (Test-Path $LocalReleaseFile) {
    $LocalTag = (Get-Content $LocalReleaseFile -Raw).Trim()
    Write-Host "Local release tag: $LocalTag"
}
else {
    $LocalTag = $null
    Write-Host "Local release tag: not found"
}

Write-Host ""
Write-Host "Checking GitHub latest release ($GitHubApi)..."
$ReleaseInfo = Get-LatestLlamaCudaRelease -Headers $Headers -CudaMajor $CudaMajor -GitHubApi $GitHubApi
$LatestTag = $ReleaseInfo.Release.tag_name
$LatestAssetPair = $ReleaseInfo.AssetPair

Write-Host "GitHub latest tag: $LatestTag"

if ($LatestAssetPair) {
    Write-Host "GitHub latest CUDA $CudaMajor.x asset: $($LatestAssetPair.MainAsset.name)"
    Write-Host "GitHub latest CUDA runtime: $($LatestAssetPair.CudaRuntimeAsset.name)"
}
else {
    Write-Host "GitHub latest CUDA $CudaMajor.x asset pair: not found"
}

Write-Host ""
if ($LocalTag -and $LocalTag -eq $LatestTag) {
    Write-Host "Result: current local llama.cpp is latest." -ForegroundColor Green
}
else {
    Write-Host "Result: current local llama.cpp is NOT latest." -ForegroundColor Yellow
}
