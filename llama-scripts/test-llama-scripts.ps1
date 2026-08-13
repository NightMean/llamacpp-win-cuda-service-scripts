$ErrorActionPreference = "Stop"

$ScriptsDir = $PSScriptRoot
$BaseDir = Split-Path -Parent $ScriptsDir
$CommonPath = Join-Path $ScriptsDir "llama-common.ps1"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

Assert-True (Test-Path $CommonPath) "llama-common.ps1 should exist."
. $CommonPath

$ResolvedRoot = Get-LlamaProjectRoot -ScriptsDir $ScriptsDir
Assert-Equal $BaseDir $ResolvedRoot "Get-LlamaProjectRoot should resolve the parent of llama-scripts."

$MockAssets = @(
    [pscustomobject]@{ name = "llama-b100-bin-win-cuda-13.1-x64.zip" },
    [pscustomobject]@{ name = "cudart-llama-bin-win-cuda-13.1-x64.zip" },
    [pscustomobject]@{ name = "llama-b101-bin-win-cuda-13.3-x64.zip" },
    [pscustomobject]@{ name = "cudart-llama-bin-win-cuda-13.3-x64.zip" },
    [pscustomobject]@{ name = "llama-b102-bin-win-cuda-12.4-x64.zip" },
    [pscustomobject]@{ name = "cudart-llama-bin-win-cuda-12.4-x64.zip" }
)

$Pair = Get-LatestWindowsCudaAssetPair -Assets $MockAssets -CudaMajor 13
Assert-Equal "llama-b101-bin-win-cuda-13.3-x64.zip" $Pair.MainAsset.name "CUDA asset pair should choose the highest matching CUDA 13.x main zip."
Assert-Equal "cudart-llama-bin-win-cuda-13.3-x64.zip" $Pair.CudaRuntimeAsset.name "CUDA asset pair should choose the matching runtime zip."

$ScriptsWithProjectRoot = @(
    "update-llamacpp-cuda13.ps1",
    "start-llamacpp-server.ps1",
    "stop-llamacpp-server.ps1",
    "restart-llamacpp-server.ps1",
    "check-llamacpp-version.ps1",
    "register-update-task-run-logged-off.ps1"
)

foreach ($ScriptName in $ScriptsWithProjectRoot) {
    $ScriptPath = Join-Path $ScriptsDir $ScriptName
    Assert-True (Test-Path $ScriptPath) "$ScriptName should exist."

    $ScriptText = Get-Content -Path $ScriptPath -Raw
    Assert-True ($ScriptText -notmatch '\$env:USERPROFILE\s+"Documents\\GitHub\\llama_cpp"') "$ScriptName should not hard-code the project under USERPROFILE."
}

$RestartScriptPath = Join-Path $ScriptsDir "restart-llamacpp-server.ps1"
Assert-True (Test-Path $RestartScriptPath) "restart-llamacpp-server.ps1 should exist."

$RestartScriptText = Get-Content -Path $RestartScriptPath -Raw
$StopInvocationIndex = $RestartScriptText.IndexOf("stop-llamacpp-server.ps1")
$StartInvocationIndex = $RestartScriptText.IndexOf("start-llamacpp-server.ps1")

Assert-True ($StopInvocationIndex -ge 0) "restart-llamacpp-server.ps1 should call stop-llamacpp-server.ps1."
Assert-True ($StartInvocationIndex -ge 0) "restart-llamacpp-server.ps1 should call start-llamacpp-server.ps1."
Assert-True ($StopInvocationIndex -lt $StartInvocationIndex) "restart-llamacpp-server.ps1 should stop before starting."
Assert-True ($RestartScriptText -match "models\.ini") "restart-llamacpp-server.ps1 should explain that it applies models.ini changes."

$StopScriptPath = Join-Path $ScriptsDir "stop-llamacpp-server.ps1"
Assert-True (Test-Path $StopScriptPath) "stop-llamacpp-server.ps1 should exist."

$StopScriptText = Get-Content -Path $StopScriptPath -Raw
Assert-True ($StopScriptText -match "Assert-ServerProcessStopped") "stop-llamacpp-server.ps1 should verify that target llama-server processes are gone after Stop-Process."
Assert-True ($StopScriptText -match "Assert-ServerPortReleased") "stop-llamacpp-server.ps1 should verify that the configured port is released after stopping."
Assert-True ($StopScriptText -match 'for \(\$Attempt = 1; \$Attempt -le 20; \$Attempt\+\+\)') "stop-llamacpp-server.ps1 should tolerate delayed Windows process-object cleanup before reporting failure."
Assert-True ($StopScriptText -match "Failed to stop llama-server process PID") "stop-llamacpp-server.ps1 should fail clearly when a target process remains after force stop."
Assert-True ($StopScriptText -match "Port .* is still owned by PID") "stop-llamacpp-server.ps1 should fail clearly when the configured port remains bound."

$TempLog = Join-Path ([System.IO.Path]::GetTempPath()) ("llama-log-test-" + [guid]::NewGuid().ToString("N") + ".log")
try {
    Set-Content -Path $TempLog -Value ("x" * 128) -NoNewline
    Start-LlamaTranscriptWithRotation -Path $TempLog -MaxBytes 64 -KeepFiles 2
    Stop-Transcript | Out-Null

    Assert-True (Test-Path "$TempLog.1") "Transcript rotation should move oversized logs to .1."
    Assert-True (Test-Path $TempLog) "Transcript rotation should create a fresh active log."
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }

    Remove-Item -Path $TempLog, "$TempLog.1", "$TempLog.2" -Force -ErrorAction SilentlyContinue
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("llama-cleanup-test-" + [guid]::NewGuid().ToString("N"))
$TempCache = Join-Path $TempRoot "cache"
New-Item -ItemType Directory -Path $TempRoot, $TempCache -Force | Out-Null

try {
    foreach ($Name in @(
        "llama-b100-bin-win-cuda-13.1-x64",
        "llama-b101-bin-win-cuda-13.3-x64",
        "llama-b102-bin-win-cuda-13.3-x64"
    )) {
        New-Item -ItemType Directory -Path (Join-Path $TempRoot $Name) -Force | Out-Null
    }

    foreach ($Name in @(
        "llama-b100-bin-win-cuda-13.1-x64.zip",
        "llama-b101-bin-win-cuda-13.3-x64.zip",
        "llama-b102-bin-win-cuda-13.3-x64.zip",
        "cudart-llama-bin-win-cuda-13.1-x64.zip",
        "cudart-llama-bin-win-cuda-13.3-x64.zip"
    )) {
        Set-Content -Path (Join-Path $TempCache $Name) -Value "test" -NoNewline
    }

    Remove-OldLlamaVersionsAndCache `
        -BaseDir $TempRoot `
        -DownloadCacheDir $TempCache `
        -ActiveInstallDir (Join-Path $TempRoot "llama-b102-bin-win-cuda-13.3-x64") `
        -CudaMajor 13 `
        -KeepVersions 2

    Assert-True (-not (Test-Path (Join-Path $TempRoot "llama-b100-bin-win-cuda-13.1-x64"))) "Cleanup should remove old install dirs beyond KeepVersions."
    Assert-True (-not (Test-Path (Join-Path $TempCache "llama-b100-bin-win-cuda-13.1-x64.zip"))) "Cleanup should remove old main zip cache files beyond KeepVersions."
    Assert-True (-not (Test-Path (Join-Path $TempCache "cudart-llama-bin-win-cuda-13.1-x64.zip"))) "Cleanup should remove old CUDA runtime zip cache files beyond KeepVersions."
    Assert-True (Test-Path (Join-Path $TempCache "cudart-llama-bin-win-cuda-13.3-x64.zip")) "Cleanup should keep current CUDA runtime zip cache file."
}
finally {
    Remove-Item -Path $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "All llama script tests passed."
