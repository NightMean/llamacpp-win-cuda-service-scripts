$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "llama-common.ps1")

$BaseDir = Get-LlamaProjectRoot -ScriptsDir $PSScriptRoot
$CurrentDir = Join-Path $BaseDir "llama-current"
$ConfigPath = Join-Path $BaseDir "llama-config\models.ini"
$RuntimeDir = Join-Path $BaseDir "llama-runtime"
$LogDir = Join-Path $BaseDir "llama-logs"

$ServerEndpoint = Get-LlamaServerEndpoint -ConfigPath $ConfigPath
$HostName = $ServerEndpoint.HostName
$Port = $ServerEndpoint.Port
$BaseUrl = $ServerEndpoint.BaseUrl

$SleepIdleSeconds = $ServerEndpoint.SleepIdleSeconds
$ModelsMax = $ServerEndpoint.ModelsMax

$PidFile = Join-Path $RuntimeDir "llama-server.pid"
$StdOutLog = Join-Path $LogDir "llama-server.out.log"
$StdErrLog = Join-Path $LogDir "llama-server.err.log"

New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Rotate-LogFile {
    param(
        [string]$Path,
        [int64]$MaxBytes = 5242880,
        [int]$KeepFiles = 3
    )

    if ((Test-Path $Path) -and ((Get-Item $Path).Length -ge $MaxBytes)) {
        for ($Index = $KeepFiles - 1; $Index -ge 1; $Index--) {
            $Source = "$Path.$Index"
            $Destination = "$Path.$($Index + 1)"
            if (Test-Path $Source) {
                Move-Item -Path $Source -Destination $Destination -Force
            }
        }
        Move-Item -Path $Path -Destination "$Path.1" -Force
    }
}

function Test-LlamaServerAlive {
    try {
        $Headers = @{}
        if ($ServerEndpoint.ApiKey) {
            $Headers["Authorization"] = "Bearer $($ServerEndpoint.ApiKey)"
        }

        Invoke-WebRequest `
            -Uri "$BaseUrl/health" `
            -Headers $Headers `
            -UseBasicParsing `
            -TimeoutSec 2 | Out-Null

        return $true
    }
    catch {
        return $false
    }
}

if (Test-LlamaServerAlive) {
    Write-Host "llama-server is already running at $BaseUrl"
    exit 0
}

$ExePath = Join-Path $CurrentDir "llama-server.exe"

if (-not (Test-Path $ExePath)) {
    throw "llama-server.exe not found: $ExePath. Please run update-llamacpp-cuda13.ps1 first."
}

if (-not (Test-Path $ConfigPath)) {
    throw "models.ini not found: $ConfigPath"
}

$ArgumentValues = @(
    "--host", $HostName,
    "--port", "$Port",
    "--models-preset", $ConfigPath,
    "--models-max", "$ModelsMax",
    "--sleep-idle-seconds", "$SleepIdleSeconds"
)

if ($ServerEndpoint.MemoryMargin) {
    $ArgumentValues += @("--models-memory-margin", "$($ServerEndpoint.MemoryMargin)")
}

if ($ServerEndpoint.Device) {
    $ArgumentValues += @("--device", "$($ServerEndpoint.Device)")
}

if ($ServerEndpoint.ApiKey) {
    $ArgumentValues += @("--api-key", "$($ServerEndpoint.ApiKey)")
}

$ArgumentString = ($ArgumentValues | ForEach-Object {
    ConvertTo-LlamaWindowsCommandLineArgument -Value $_
}) -join " "

Rotate-LogFile -Path $StdOutLog
Rotate-LogFile -Path $StdErrLog

Write-Host "Starting llama-server..."
Write-Host "$ExePath $ArgumentString"

$Process = Start-Process `
    -FilePath $ExePath `
    -ArgumentList $ArgumentString `
    -WorkingDirectory $CurrentDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdOutLog `
    -RedirectStandardError $StdErrLog `
    -PassThru

Set-Content -Path $PidFile -Value $Process.Id

for ($i = 1; $i -le 60; $i++) {
    Start-Sleep -Seconds 1

    if (Test-LlamaServerAlive) {
        Write-Host "llama-server started: $BaseUrl"
        exit 0
    }

    if ($Process.HasExited) {
        throw "llama-server exited early. Check log: $StdErrLog"
    }
}

throw "llama-server did not become healthy within 60 seconds. Check logs in $LogDir"
