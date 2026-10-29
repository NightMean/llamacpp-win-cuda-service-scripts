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

$ParseErrors = @()
foreach ($PowerShellScript in Get-ChildItem -Path $ScriptsDir -Filter "*.ps1") {
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PowerShellScript.FullName,
        [ref]$Tokens,
        [ref]$Errors
    )
    $ParseErrors += $Errors
}
Assert-Equal 0 $ParseErrors.Count "All PowerShell scripts should parse without syntax errors."

$ResolvedRoot = Get-LlamaProjectRoot -ScriptsDir $ScriptsDir
Assert-Equal $BaseDir $ResolvedRoot "Get-LlamaProjectRoot should resolve the parent of llama-scripts."

Assert-Equal "plain" (ConvertTo-LlamaWindowsCommandLineArgument -Value "plain") "Plain native arguments should not be quoted."
Assert-Equal '"C:\Program Files\llama.cpp\models.ini"' (ConvertTo-LlamaWindowsCommandLineArgument -Value "C:\Program Files\llama.cpp\models.ini") "Paths containing spaces should be quoted."
Assert-Equal '""' (ConvertTo-LlamaWindowsCommandLineArgument -Value "") "Empty native arguments should be quoted."

$TempEndpointConfig = Join-Path ([System.IO.Path]::GetTempPath()) ("llama-endpoint-test-" + [guid]::NewGuid().ToString("N") + ".ini")
try {
    Set-Content -Path $TempEndpointConfig -Value @(
        "version = 1",
        "",
        "[*]",
        "host = 0.0.0.0",
        "port = 18080",
        "api-key = secret123",
        "memory-margin = 1024",
        "device = 0",
        "sleep-idle-seconds = 600",
        "models-max = 2",
        "",
        "[example]",
        "port = 9999"
    )

    $Endpoint = Get-LlamaServerEndpoint -ConfigPath $TempEndpointConfig
    Assert-Equal "0.0.0.0" $Endpoint.HostName "The global models.ini host should control the server bind address."
    Assert-Equal 18080 $Endpoint.Port "The global models.ini port should control the server port."
    Assert-Equal "http://127.0.0.1:18080" $Endpoint.BaseUrl "A wildcard bind address should use loopback for health checks."
    Assert-Equal "secret123" $Endpoint.ApiKey "api-key should be parsed from models.ini."
    Assert-Equal "1024" $Endpoint.MemoryMargin "memory-margin should be parsed from models.ini."
    Assert-Equal "0" $Endpoint.Device "device should be parsed from models.ini."
    Assert-Equal 600 $Endpoint.SleepIdleSeconds "sleep-idle-seconds should be parsed from models.ini."
    Assert-Equal 2 $Endpoint.ModelsMax "models-max should be parsed from models.ini."
}
finally {
    Remove-Item -Path $TempEndpointConfig -Force -ErrorAction SilentlyContinue
}

$DetectedMajor = Get-LlamaDetectedCudaMajor -DefaultMajor 13
Assert-True ($DetectedMajor -ge 10) "Get-LlamaDetectedCudaMajor should return a valid CUDA major version."

$ManagedConfigPath = "C:\Portable Install\llama-config\models.ini"
$ManagedCurrentDir = "C:\Portable Install\llama-current"
$ManagedByConfig = [pscustomobject]@{
    Name = "llama-server.exe"
    CommandLine = "llama-server.exe --models-preset `"$ManagedConfigPath`""
    ExecutablePath = "C:\Versioned Build\llama-server.exe"
}
$ManagedByExecutable = [pscustomobject]@{
    Name = "llama-server.exe"
    CommandLine = "llama-server.exe"
    ExecutablePath = "$ManagedCurrentDir\llama-server.exe"
}
$UnrelatedSameName = [pscustomobject]@{
    Name = "llama-server.exe"
    CommandLine = "llama-server.exe --models-preset C:\Other\models.ini"
    ExecutablePath = "C:\Other\llama-server.exe"
}
$InaccessibleSameName = [pscustomobject]@{
    Name = "llama-server.exe"
    CommandLine = $null
    ExecutablePath = $null
}
Assert-True (Test-LlamaManagedServerProcess -Process $ManagedByConfig -CurrentDir $ManagedCurrentDir -ConfigPath $ManagedConfigPath) "A process using this installation's config should be managed."
Assert-True (Test-LlamaManagedServerProcess -Process $ManagedByExecutable -CurrentDir $ManagedCurrentDir -ConfigPath $ManagedConfigPath) "A process under llama-current should be managed."
Assert-True (-not (Test-LlamaManagedServerProcess -Process $UnrelatedSameName -CurrentDir $ManagedCurrentDir -ConfigPath $ManagedConfigPath)) "A same-named process from another installation should not be managed."
Assert-True (-not (Test-LlamaManagedServerProcess -Process $InaccessibleSameName -CurrentDir $ManagedCurrentDir -ConfigPath $ManagedConfigPath)) "A process with inaccessible identity details should fail closed."

$CreateMode = Get-LlamaScheduledTaskRegistrationMode -ExistingTask $null
$ReplaceMode = Get-LlamaScheduledTaskRegistrationMode -ExistingTask ([pscustomobject]@{ TaskName = "existing" })
Assert-Equal "Created" $CreateMode.Result "A missing scheduled task should select creation mode."
Assert-True (-not $CreateMode.ShouldForce) "A new scheduled task should not request forced replacement."
Assert-Equal "Replaced" $ReplaceMode.Result "An existing scheduled task should select replacement mode."
Assert-True $ReplaceMode.ShouldForce "An existing scheduled task should request forced replacement."

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
    "register-start-task-at-startup.ps1",
    "register-update-task-run-logged-off.ps1"
)

foreach ($ScriptName in $ScriptsWithProjectRoot) {
    $ScriptPath = Join-Path $ScriptsDir $ScriptName
    Assert-True (Test-Path $ScriptPath) "$ScriptName should exist."

    $ScriptText = Get-Content -Path $ScriptPath -Raw
    Assert-True ($ScriptText -notmatch '\$env:USERPROFILE\s+"Documents\\GitHub\\llama_cpp"') "$ScriptName should not hard-code the project under USERPROFILE."
}

foreach ($ScriptName in @("start-llamacpp-server.ps1", "stop-llamacpp-server.ps1", "update-llamacpp-cuda13.ps1")) {
    $ScriptText = Get-Content -Path (Join-Path $ScriptsDir $ScriptName) -Raw
    Assert-True ($ScriptText -match "Get-LlamaServerEndpoint") "$ScriptName should read the shared endpoint from models.ini."
    Assert-True ($ScriptText -notmatch '\$HostName\s*=\s*"127\.0\.0\.1"') "$ScriptName should not duplicate the default host."
    Assert-True ($ScriptText -notmatch '\$Port\s*=\s*8080') "$ScriptName should not duplicate the default port."
}

$StartScriptText = Get-Content -Path (Join-Path $ScriptsDir "start-llamacpp-server.ps1") -Raw
Assert-True ($StartScriptText -match "ConvertTo-LlamaWindowsCommandLineArgument") "The start script should quote native arguments safely."
Assert-True ($StartScriptText -match '\-ArgumentList\s+\$ArgumentString') "The start script should pass one explicitly quoted argument string to Start-Process."

$RegisterStartTaskPath = Join-Path $ScriptsDir "register-start-task-at-startup.ps1"
$RegisterStartTaskText = Get-Content -Path $RegisterStartTaskPath -Raw
Assert-True ($RegisterStartTaskText -match 'New-ScheduledTaskTrigger\s+-AtStartup') "The server task should use a Windows startup trigger."
Assert-True ($RegisterStartTaskText -match '\-LogonType\s+S4U') "The server task should run without an interactive user logon."
Assert-True ($RegisterStartTaskText -match '\-RunLevel\s+Highest') "The server task should run with highest privileges."
Assert-True ($RegisterStartTaskText -match '\$TaskUserId\s*=\s*\$Identity\.Name') "The server task should use the Windows identity instead of assuming an environment-variable account format."
Assert-True ($RegisterStartTaskText -match 'Get-LlamaScheduledTaskRegistrationMode') "The server task registration should distinguish an existing task from a new installation."
Assert-True ($RegisterStartTaskText -match '\$RegisterParams\.Force\s*=\s*\$true') "The server task registration should only request replacement when the task already exists."

$RegisterUpdateTaskPath = Join-Path $ScriptsDir "register-update-task-run-logged-off.ps1"
$RegisterUpdateTaskText = Get-Content -Path $RegisterUpdateTaskPath -Raw
Assert-True ($RegisterUpdateTaskText -match '\$TaskUserId\s*=\s*\$Identity\.Name') "The update task should use the actual Windows identity."
Assert-True ($RegisterUpdateTaskText -notmatch '\$env:USERDOMAIN|\$env:USERNAME') "The update task should not construct an account from environment variables."
Assert-True ($RegisterUpdateTaskText -match 'Get-LlamaScheduledTaskRegistrationMode') "The update task registration should distinguish an existing task from a new installation."
Assert-True ($RegisterUpdateTaskText -match '\$RegisterParams\.Force\s*=\s*\$true') "The update task should only request replacement when the task already exists."

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
Assert-True ($StopScriptText -match "Test-LlamaManagedServerProcess") "stop-llamacpp-server.ps1 should verify PID ownership before stopping a process."
Assert-True ($StopScriptText -match "Ignoring unverified PID file") "stop-llamacpp-server.ps1 should report an unverified PID instead of stopping an unrelated process."
Assert-True ($StopScriptText -match "Refusing to unload models") "stop-llamacpp-server.ps1 should not call another installation's model API when process identity is unverified."

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

# Test mock release scanning logic
$MockReleases = @(
    [pscustomobject]@{
        tag_name = "v0.8.0"
        prerelease = $false
        assets = @(
            [pscustomobject]@{ name = "llama-v0.8.0-bin-win-x64.zip" }
        )
    },
    [pscustomobject]@{
        tag_name = "b11988"
        prerelease = $true
        assets = @(
            [pscustomobject]@{ name = "llama-b11988-bin-win-cuda-13.4-x64.zip" },
            [pscustomobject]@{ name = "cudart-llama-bin-win-cuda-13.4-x64.zip" }
        )
    }
)
$FoundPair = $null
foreach ($Rel in $MockReleases) {
    try {
        $FoundPair = Get-LatestWindowsCudaAssetPair -Assets $Rel.assets -CudaMajor 13
        if ($FoundPair) { break }
    } catch {}
}
Assert-True ($null -ne $FoundPair) "Scanner should discover CUDA asset pair even when releases contain non-matching tags."
Assert-Equal 11988 $FoundPair.Build "Scanner should resolve the correct build number from mock assets."

Write-Host "All llama script tests passed."
