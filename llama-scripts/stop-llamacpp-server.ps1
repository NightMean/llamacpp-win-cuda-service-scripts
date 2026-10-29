$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "llama-common.ps1")

$BaseDir = Get-LlamaProjectRoot -ScriptsDir $PSScriptRoot
$RuntimeDir = Join-Path $BaseDir "llama-runtime"
$PidFile = Join-Path $RuntimeDir "llama-server.pid"
$CurrentDir = Join-Path $BaseDir "llama-current"
$ConfigPath = Join-Path $BaseDir "llama-config\models.ini"

$ServerEndpoint = Get-LlamaServerEndpoint -ConfigPath $ConfigPath
$HostName = $ServerEndpoint.HostName
$Port = $ServerEndpoint.Port
$BaseUrl = $ServerEndpoint.BaseUrl

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

function Test-ManagedServerOwnsEndpoint {
    $Listeners = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue

    foreach ($Listener in $Listeners) {
        $ListenerProcess = Get-CimInstance Win32_Process `
            -Filter "ProcessId = $($Listener.OwningProcess)" `
            -ErrorAction SilentlyContinue

        if (Test-LlamaManagedServerProcess `
            -Process $ListenerProcess `
            -CurrentDir $CurrentDir `
            -ConfigPath $ConfigPath) {
            return $true
        }
    }

    return $false
}

function Unload-LoadedModels {
    if (-not (Test-LlamaServerAlive)) {
        return
    }

    if (-not (Test-ManagedServerOwnsEndpoint)) {
        Write-Warning "Refusing to unload models because the process on $BaseUrl could not be verified as this llama.cpp installation."
        return
    }

    try {
        Write-Host "Querying loaded models..."
        $Headers = @{}
        if ($ServerEndpoint.ApiKey) {
            $Headers["Authorization"] = "Bearer $($ServerEndpoint.ApiKey)"
        }

        $ModelsResponse = Invoke-RestMethod `
            -Method Get `
            -Uri "$BaseUrl/models" `
            -Headers $Headers `
            -TimeoutSec 10

        foreach ($Model in $ModelsResponse.data) {
            $Status = $Model.status.value

            if ($Status -eq "loaded" -or $Status -eq "loading") {
                $ModelId = $Model.id
                Write-Host "Unloading model: $ModelId"

                $Body = @{
                    model = $ModelId
                } | ConvertTo-Json -Compress

                Invoke-RestMethod `
                    -Method Post `
                    -Uri "$BaseUrl/models/unload" `
                    -Headers $Headers `
                    -ContentType "application/json" `
                    -Body $Body `
                    -TimeoutSec 60 | Out-Null
            }
        }
    }
    catch {
        Write-Warning "Failed to unload models via API. Will stop process anyway."
        Write-Warning $_
    }
}

function Assert-ServerProcessStopped {
    param([int]$PidValue)

    for ($Attempt = 1; $Attempt -le 20; $Attempt++) {
        $RemainingProcess = Get-Process -Id $PidValue -ErrorAction SilentlyContinue

        if (-not $RemainingProcess -or $RemainingProcess.ProcessName -ine "llama-server") {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    $RemainingProcess = Get-Process -Id $PidValue -ErrorAction SilentlyContinue
    if ($RemainingProcess -and $RemainingProcess.ProcessName -ieq "llama-server") {
        throw "Failed to stop llama-server process PID $PidValue. Run PowerShell as administrator or stop the scheduled-task-owned process manually."
    }
}

function Assert-ServerPortReleased {
    for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
        $Listeners = Get-NetTCPConnection `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue

        if (-not $Listeners) {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    $Listeners = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue

    if ($Listeners) {
        $OwnerPids = $Listeners |
        Select-Object -ExpandProperty OwningProcess -Unique

        throw "Port $Port is still owned by PID $($OwnerPids -join ', ') after stopping llama-server. Run PowerShell as administrator or stop the scheduled-task-owned process manually."
    }
}

function Stop-ServerProcess {
    $PidCandidates = @()

    if (Test-Path $PidFile) {
        $SavedPid = (Get-Content $PidFile -Raw).Trim()
        if ($SavedPid -match "^\d+$") {
            $SavedProcess = Get-CimInstance Win32_Process `
                -Filter "ProcessId = $SavedPid" `
                -ErrorAction SilentlyContinue

            if (Test-LlamaManagedServerProcess `
                -Process $SavedProcess `
                -CurrentDir $CurrentDir `
                -ConfigPath $ConfigPath) {
                $PidCandidates += [int]$SavedPid
            }
            elseif ($SavedProcess) {
                Write-Warning "Ignoring unverified PID file: PID $SavedPid does not match this llama.cpp installation or its details are inaccessible."
            }
        }
    }

    $Processes = Get-CimInstance Win32_Process |
    Where-Object {
        Test-LlamaManagedServerProcess `
            -Process $_ `
            -CurrentDir $CurrentDir `
            -ConfigPath $ConfigPath
    }

    foreach ($Proc in $Processes) {
        $PidCandidates += [int]$Proc.ProcessId
    }

    $PidCandidates = $PidCandidates | Select-Object -Unique

    foreach ($PidValue in $PidCandidates) {
        $Proc = Get-Process -Id $PidValue -ErrorAction SilentlyContinue

        if ($Proc -and $Proc.ProcessName -ieq "llama-server") {
            Write-Host "Stopping llama-server process PID $PidValue"
            Stop-Process -Id $PidValue -ErrorAction SilentlyContinue

            try {
                Wait-Process -Id $PidValue -Timeout 30 -ErrorAction Stop
            }
            catch {
                Write-Warning "Process did not exit in 30 seconds. Killing PID $PidValue"
                Stop-Process -Id $PidValue -Force -ErrorAction Stop
                Wait-Process -Id $PidValue -Timeout 10 -ErrorAction SilentlyContinue
            }

            Assert-ServerProcessStopped -PidValue $PidValue
        }
    }

    Assert-ServerPortReleased
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

Unload-LoadedModels
Start-Sleep -Seconds 2
Stop-ServerProcess

Write-Host "llama-server stopped."
