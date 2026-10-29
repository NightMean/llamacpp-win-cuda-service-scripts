param(
    [string]$ConfigPathOverride = $null
)

$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "llama-common.ps1")

$BaseDir = Get-LlamaProjectRoot -ScriptsDir $PSScriptRoot
$CurrentLink = Join-Path $BaseDir "llama-current"
$ConfigPath = if ($ConfigPathOverride) { $ConfigPathOverride } else { Join-Path $BaseDir "llama-config\models.ini" }

$ServerEndpoint = Get-LlamaServerEndpoint -ConfigPath $ConfigPath
$BaseUrl = $ServerEndpoint.BaseUrl

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "       llama.cpp Server Status Checker       " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# 1. Process Check
$Processes = Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq "llama-server.exe" }
if ($Processes) {
    foreach ($P in $Processes) {
        Write-Host "[+] Process: RUNNING (PID: $($P.ProcessId))" -ForegroundColor Green
    }
}
else {
    Write-Host "[-] Process: NOT RUNNING" -ForegroundColor Yellow
}

$ReqHeaders = @{}
if ($ServerEndpoint.ApiKey) {
    $ReqHeaders["Authorization"] = "Bearer $($ServerEndpoint.ApiKey)"
}

# 2. HTTP Health Endpoint Check
try {
    $Health = Invoke-RestMethod -Uri "$BaseUrl/health" -Headers $ReqHeaders -Method Get -TimeoutSec 3 -ErrorAction Stop
    $HealthStatus = if ($Health.status) { $Health.status } else { "ok" }
    Write-Host "[+] Health Endpoint: $HealthStatus ($BaseUrl/health)" -ForegroundColor Green
}
catch {
    Write-Host "[-] Health Endpoint: Unreachable ($BaseUrl/health)" -ForegroundColor Yellow
}

# 3. Model Presets Count in models.ini
if (Test-Path $ConfigPath) {
    $PresetCount = (Select-String -Path $ConfigPath -Pattern "^\[(?!\*)[^\]]+\]").Count
    Write-Host "[+] Configured Presets: $PresetCount ($ConfigPath)" -ForegroundColor Gray
}
else {
    Write-Host "[*] Configuration file not found at: $ConfigPath" -ForegroundColor DarkGray
}

# 4. Active Models in VRAM
try {
    $Models = Invoke-RestMethod -Uri "$BaseUrl/models" -Headers $ReqHeaders -Method Get -TimeoutSec 3 -ErrorAction Stop
    $LoadedModels = @($Models.data | Where-Object { $_.status.value -eq "loaded" })
    if ($LoadedModels.Count -gt 0) {
        foreach ($M in $LoadedModels) {
            Write-Host "[+] Active in VRAM: $($M.id)" -ForegroundColor Magenta
        }
    }
    else {
        Write-Host "[*] Models in VRAM: None (Idle / Zero VRAM state)" -ForegroundColor DarkCyan
    }
}
catch {
    # If server is not responding, skip
}

# 5. GPU & VRAM Status (via nvidia-smi if available)
$NvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($NvidiaSmi) {
    try {
        $GpuInfo = & $NvidiaSmi.Source --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($GpuInfo) {
            $Parts = $GpuInfo.Trim() -split ',\s*'
            if ($Parts.Count -ge 4) {
                $GpuName = $Parts[0]
                $MemUsed = [int]$Parts[1]
                $MemTotal = [int]$Parts[2]
                $GpuUtil = $Parts[3]
                $MemPercent = [Math]::Round(($MemUsed / [Math]::Max(1, $MemTotal)) * 100, 1)
                Write-Host "[+] $GpuName VRAM: $MemUsed MB / $MemTotal MB ($MemPercent%) | GPU Load: $GpuUtil%" -ForegroundColor White
            }
        }
    }
    catch {
        # Ignore nvidia-smi errors
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
