param(
    [ValidateRange(0, 99)]
    [int]$CudaMajor = 0,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "llama-common.ps1")

if ($CudaMajor -le 0) {
    $CudaMajor = Get-LlamaDetectedCudaMajor -DefaultMajor 13
}

# =========================
# User configuration
# =========================
$BaseDir = Get-LlamaProjectRoot -ScriptsDir $PSScriptRoot
$CurrentLink = Join-Path $BaseDir "llama-current"
$ScriptsDir = Join-Path $BaseDir "llama-scripts"
$DownloadCacheDir = Join-Path $BaseDir "llama-download-cache"
$LogDir = Join-Path $BaseDir "llama-logs"
$ConfigPath = Join-Path $BaseDir "llama-config\models.ini"

$StopScript = Join-Path $ScriptsDir "stop-llamacpp-server.ps1"
$StartScript = Join-Path $ScriptsDir "start-llamacpp-server.ps1"

$GitHubApi = "https://api.github.com/repos/ggml-org/llama.cpp/releases"
$ServerEndpoint = Get-LlamaServerEndpoint -ConfigPath $ConfigPath
$HostName = $ServerEndpoint.HostName
$Port = $ServerEndpoint.Port
$BaseUrl = $ServerEndpoint.BaseUrl

# Keep local old versions and cached main zips after a successful update.
$KeepVersions = 2

# =========================
# Setup
# =========================
New-Item -ItemType Directory -Path $DownloadCacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$TranscriptPath = Join-Path $LogDir "update-llamacpp-cuda13.log"
$TranscriptStarted = $false

try {
    Start-LlamaTranscriptWithRotation -Path $TranscriptPath
    $TranscriptStarted = $true
}
catch {
    Write-Warning "Could not start transcript logging: $($_.Exception.Message)"
}

# Prefer TLS 1.2 on older Windows PowerShell builds.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Warning "Could not force TLS 1.2: $($_.Exception.Message)"
}

$Headers = New-LlamaGitHubHeaders -BaseDir $BaseDir -UserAgent "llamacpp-auto-updater"

if (Test-LlamaGitHubTokenConfigured -Headers $Headers) {
    Write-Host "GitHub token: configured."
}
else {
    Write-Warning "GitHub token is not configured. Unauthenticated GitHub API rate limits may stop the update."
}

$StoppedServer = $false
$OldTarget = $null
$InstallDir = $null

# =========================
# Functions
# =========================
function Write-Section {
    param([string]$Text)

    Write-Host ""
    Write-Host "===== $Text ====="
}

function Test-LlamaServerAlive {
    try {
        Invoke-WebRequest -Uri "$BaseUrl/health" -UseBasicParsing -TimeoutSec 2 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-CurrentLinkTarget {
    if (-not (Test-Path $CurrentLink)) {
        return $null
    }

    $Item = Get-Item $CurrentLink -Force

    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($Item.Target -is [array]) {
            return $Item.Target[0]
        }
        return $Item.Target
    }

    return $Item.FullName
}

function Download-FileWithProgressBar {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    $HttpClientHandler = [System.Net.Http.HttpClientHandler]::new()
    $HttpClient = [System.Net.Http.HttpClient]::new($HttpClientHandler)
    $HttpClient.Timeout = [System.TimeSpan]::FromMinutes(10)

    try {
        $Response = $HttpClient.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$Response.EnsureSuccessStatusCode()

        $TotalBytes = $Response.Content.Headers.ContentLength
        $Stream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $FileStream = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $Buffer = [byte[]]::new(65536)
        $BytesRead = 0
        $TotalBytesRead = 0
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $LastUpdate = [System.Diagnostics.Stopwatch]::StartNew()

        while (($BytesRead = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $FileStream.Write($Buffer, 0, $BytesRead)
            $TotalBytesRead += $BytesRead

            if ($LastUpdate.ElapsedMilliseconds -ge 200 -or ($TotalBytes -and $TotalBytesRead -ge $TotalBytes)) {
                $ElapsedSec = [Math]::Max(0.001, $Stopwatch.Elapsed.TotalSeconds)
                $SpeedMBps = ($TotalBytesRead / 1MB) / $ElapsedSec
                $DownloadedMB = $TotalBytesRead / 1MB

                if ($TotalBytes -and $TotalBytes -gt 0) {
                    $Percent = [Math]::Min(100, [int](($TotalBytesRead / $TotalBytes) * 100))
                    $TotalMB = $TotalBytes / 1MB
                    $BarWidth = 25
                    $Filled = [Math]::Min($BarWidth, [int](($Percent / 100) * $BarWidth))
                    $Bar = ("=" * $Filled) + (" " * ($BarWidth - $Filled))
                    $Status = "`r[$Bar] $Percent% | $([Math]::Round($DownloadedMB, 1)) / $([Math]::Round($TotalMB, 1)) MB | $([Math]::Round($SpeedMBps, 1)) MB/s"
                }
                else {
                    $Status = "`r[Streaming] $([Math]::Round($DownloadedMB, 1)) MB | $([Math]::Round($SpeedMBps, 1)) MB/s"
                }

                Write-Host -NoNewline $Status
                $LastUpdate.Restart()
            }
        }

        Write-Host ""
        $FileStream.Flush()
    }
    finally {
        if ($FileStream) { $FileStream.Dispose() }
        if ($Stream) { $Stream.Dispose() }
        if ($Response) { $Response.Dispose() }
        if ($HttpClient) { $HttpClient.Dispose() }
    }
}

function Invoke-WebRequestWithRetry {
    param(
        [string]$Uri,
        [string]$OutFile,
        [int]$Retries = 3
    )

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        try {
            Download-FileWithProgressBar -Uri $Uri -OutFile $OutFile
            return
        }
        catch {
            $Message = $_.Exception.Message
            Write-Warning "Streaming download attempt $Attempt/$Retries failed ($Message). Falling back to Invoke-WebRequest..."
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -TimeoutSec 600
                return
            }
            catch {
                $FallbackMessage = $_.Exception.Message
                Write-Warning "Download failed, attempt $Attempt/$Retries`: $FallbackMessage"

                if ($Attempt -ge $Retries) {
                    throw
                }

                Start-Sleep -Seconds ([Math]::Min(30, 5 * $Attempt))
            }
        }
    }
}

function Copy-ZipContentToInstallDir {
    param(
        [string]$ZipPath,
        [string]$DestinationDir
    )

    $ExtractDir = Join-Path `
        ([System.IO.Path]::GetDirectoryName($ZipPath)) `
        ([System.IO.Path]::GetFileNameWithoutExtension($ZipPath))

    Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $TotalEntries = $Archive.Entries.Count
            $CurrentIndex = 0
            $LastPercent = -1

            foreach ($Entry in $Archive.Entries) {
                $CurrentIndex++
                $Percent = [int](($CurrentIndex / [Math]::Max(1, $TotalEntries)) * 100)
                if ($Percent -ne $LastPercent -and ($Percent % 10 -eq 0 -or $Percent -eq 100)) {
                    Write-Host -NoNewline "`rExtracting: $Percent% ($CurrentIndex / $TotalEntries files)"
                    $LastPercent = $Percent
                }
                $DestFilePath = [System.IO.Path]::Combine($ExtractDir, $Entry.FullName)
                $DestDirPath = [System.IO.Path]::GetDirectoryName($DestFilePath)
                if ($DestDirPath -and -not (Test-Path $DestDirPath)) {
                    [System.IO.Directory]::CreateDirectory($DestDirPath) | Out-Null
                }
                if (-not $Entry.FullName.EndsWith("/") -and -not $Entry.FullName.EndsWith("\")) {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $DestFilePath, $true)
                }
            }
            Write-Host ""
        }
        finally {
            $Archive.Dispose()
        }
    }
    catch {
        Write-Warning "ZipFile extraction encountered error, falling back to Expand-Archive: $($_.Exception.Message)"
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
    }

    $Items = Get-ChildItem -Path $ExtractDir

    if ($Items.Count -eq 1 -and $Items[0].PSIsContainer) {
        $ContentRoot = $Items[0].FullName
    }
    else {
        $ContentRoot = $ExtractDir
    }

    Copy-Item `
        -Path (Join-Path $ContentRoot "*") `
        -Destination $DestinationDir `
        -Recurse `
        -Force

    Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-AssetExpectedSha256 {
    param([object]$Asset)

    if ($Asset.digest -and $Asset.digest -match "^sha256:([a-fA-F0-9]{64})$") {
        return $Matches[1].ToLowerInvariant()
    }

    return $null
}

function Get-ReleaseAssetZip {
    param(
        [object]$Asset,
        [string]$CacheDir
    )

    $ZipPath = Join-Path $CacheDir $Asset.name
    $TempZipPath = "$ZipPath.download"
    $ExpectedSha256 = Get-AssetExpectedSha256 -Asset $Asset

    if ((Test-Path $ZipPath) -and $ExpectedSha256) {
        $ActualSha256 = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($ActualSha256 -eq $ExpectedSha256) {
            Write-Host "Using cached $($Asset.name), sha256 matched."
            return $ZipPath
        }

        Write-Warning "Cached $($Asset.name) sha256 mismatch. Re-downloading."
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path $ZipPath) {
        Write-Warning "No sha256 digest available for cached $($Asset.name). Re-downloading to be safe."
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
    }

    Remove-Item $TempZipPath -Force -ErrorAction SilentlyContinue

    Write-Host "Downloading $($Asset.name)..."
    Invoke-WebRequestWithRetry -Uri $Asset.browser_download_url -OutFile $TempZipPath

    if ($ExpectedSha256) {
        $ActualSha256 = (Get-FileHash -Path $TempZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($ActualSha256 -ne $ExpectedSha256) {
            Remove-Item $TempZipPath -Force -ErrorAction SilentlyContinue
            throw "SHA256 verification failed for $($Asset.name). Expected $ExpectedSha256, got $ActualSha256"
        }

        Write-Host "Verified sha256 for $($Asset.name)."
    }
    else {
        Write-Warning "Downloaded $($Asset.name), but GitHub did not provide sha256 digest."
    }

    Move-Item -Path $TempZipPath -Destination $ZipPath -Force
    return $ZipPath
}

function Stop-LlamaServerSafely {
    if (-not (Test-Path $StopScript)) {
        Write-Warning "Stop script not found: $StopScript"
        return
    }

    Write-Host "Stopping llama-server before switching version..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopScript
}

function Start-LlamaServerSafely {
    if (-not (Test-Path $StartScript)) {
        throw "Start script not found: $StartScript"
    }

    Write-Host "Starting llama-server..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript

    if (-not (Test-LlamaServerAlive)) {
        throw "llama-server was started by script, but health check failed: $BaseUrl/health"
    }
}

function Set-CurrentLinkToInstallDir {
    param([string]$TargetDir)

    if (-not (Test-Path (Join-Path $TargetDir "llama-server.exe"))) {
        throw "Refusing to switch: llama-server.exe not found in $TargetDir"
    }

    if (Test-Path $CurrentLink) {
        $Item = Get-Item $CurrentLink -Force

        if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$CurrentLink already exists and is not a junction/symlink. Refusing to remove it."
        }

        Remove-Item $CurrentLink -Force -Recurse -Confirm:$false
    }

    Write-Host "Creating llama-current junction -> $TargetDir"
    New-Item -ItemType Junction -Path $CurrentLink -Target $TargetDir | Out-Null
}

# =========================
# Main update flow
# =========================
try {
    Write-Section "Current state"
    $OldTarget = Get-CurrentLinkTarget
    Write-Host "BaseDir:     $BaseDir"
    Write-Host "CurrentLink: $CurrentLink"
    Write-Host "Old target:  $OldTarget"
    Write-Host "Server alive before update: $(Test-LlamaServerAlive)"

    Write-Section "Checking latest llama.cpp release"
    Write-Host "GitHub API endpoint: $GitHubApi"
    $ReleaseInfo = Get-LatestLlamaCudaRelease -Headers $Headers -CudaMajor $CudaMajor -GitHubApi $GitHubApi
    $Release = $ReleaseInfo.Release
    $AssetPair = $ReleaseInfo.AssetPair
    $MainAsset = $AssetPair.MainAsset
    $CudaRuntimeAsset = $AssetPair.CudaRuntimeAsset

    Write-Host "Main asset:         $($MainAsset.name)"
    Write-Host "CUDA runtime asset: $($CudaRuntimeAsset.name)"
    Write-Host "CUDA version:       $($AssetPair.CudaVersion)"

    $BuildName = [System.IO.Path]::GetFileNameWithoutExtension($MainAsset.name)
    $InstallDir = Join-Path $BaseDir $BuildName

    if ($CheckOnly) {
        Write-Section "Check only"
        Write-Host "Selected install dir: $InstallDir"
        exit 0
    }

    if ($OldTarget -and (([System.IO.Path]::GetFullPath($OldTarget.TrimEnd('\'))) -eq ([System.IO.Path]::GetFullPath($InstallDir.TrimEnd('\'))))) {
        Write-Section "Already current"
        Write-Host "llama-current already points to latest install dir: $InstallDir"

        if (-not (Test-LlamaServerAlive)) {
            Write-Host "Server is not alive; starting existing current version."
            Start-LlamaServerSafely
        }
        else {
            Write-Host "Server is already alive."
        }

        exit 0
    }

    Write-Section "Preparing install dir before stopping server"
    if (Test-Path (Join-Path $InstallDir "llama-server.exe")) {
        Write-Host "Already installed: $InstallDir"
    }
    else {
        if (Test-Path $InstallDir) {
            Write-Warning "Install dir exists but llama-server.exe is missing. Recreating: $InstallDir"
            Remove-Item $InstallDir -Recurse -Force
        }

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

        foreach ($Asset in @($MainAsset, $CudaRuntimeAsset)) {
            $ZipPath = Get-ReleaseAssetZip -Asset $Asset -CacheDir $DownloadCacheDir

            Write-Host "Extracting $($Asset.name)..."
            Copy-ZipContentToInstallDir -ZipPath $ZipPath -DestinationDir $InstallDir
        }

        if (-not (Test-Path (Join-Path $InstallDir "llama-server.exe"))) {
            throw "Install failed: llama-server.exe not found in $InstallDir"
        }

        Set-Content -Path (Join-Path $InstallDir ".llamacpp-release") -Value $Release.tag_name
        Write-Host "Installed: $InstallDir"
    }

    Write-Section "Switching current version"
    Stop-LlamaServerSafely
    $StoppedServer = $true

    Set-CurrentLinkToInstallDir -TargetDir $InstallDir

    Write-Section "Starting updated server"
    Start-LlamaServerSafely

    Write-Section "Cleanup"
    Remove-OldLlamaVersionsAndCache `
        -BaseDir $BaseDir `
        -DownloadCacheDir $DownloadCacheDir `
        -ActiveInstallDir $InstallDir `
        -CudaMajor $CudaMajor `
        -KeepVersions $KeepVersions

    Write-Section "Done"
    Write-Host "Current llama.cpp path: $CurrentLink"
    Write-Host "Real install path:      $InstallDir"
    Write-Host "Health URL:             $BaseUrl/health"
    exit 0
}
catch {
    Write-Section "Update failed"
    Write-Error $_

    if ($StoppedServer) {
        Write-Warning "The server was stopped during switching. Attempting rollback/restart."

        try {
            if ($OldTarget -and (Test-Path (Join-Path $OldTarget "llama-server.exe"))) {
                Write-Warning "Rolling back llama-current to previous target: $OldTarget"
                Set-CurrentLinkToInstallDir -TargetDir $OldTarget
            }
            else {
                Write-Warning "Previous target is unavailable or invalid; rollback link was not changed."
            }

            Start-LlamaServerSafely
            Write-Warning "Rollback/restart succeeded."
        }
        catch {
            Write-Error "Rollback/restart failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "The server was not stopped by this script before the failure, so the old running server should be unaffected."
    }

    exit 1
}
finally {
    if ($TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Ignore transcript shutdown errors.
        }
    }
}
