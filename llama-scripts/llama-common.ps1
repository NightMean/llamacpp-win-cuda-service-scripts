function Get-LlamaProjectRoot {
    param([string]$ScriptsDir = $PSScriptRoot)

    return (Split-Path -Parent $ScriptsDir)
}

function Get-LlamaServerEndpoint {
    param(
        [string]$ConfigPath,
        [string]$DefaultHostName = "127.0.0.1",
        [ValidateRange(1, 65535)]
        [int]$DefaultPort = 8080
    )

    $HostName = $DefaultHostName
    $Port = $DefaultPort
    $ApiKey = $null
    $MemoryMargin = $null
    $Device = $null
    $SleepIdleSeconds = 1800
    $ModelsMax = 1

    if (Test-Path $ConfigPath) {
        $InGlobalSection = $false

        foreach ($Line in Get-Content -Path $ConfigPath) {
            $TrimmedLine = $Line.Trim()

            if (-not $TrimmedLine -or $TrimmedLine.StartsWith("#") -or $TrimmedLine.StartsWith(";")) {
                continue
            }

            if ($TrimmedLine -match "^\[(?<Section>[^]]+)\]$") {
                $InGlobalSection = $Matches.Section.Trim() -eq "*"
                continue
            }

            if (-not $InGlobalSection -or $TrimmedLine -notmatch "^(?<Key>[^=]+)=(?<Value>.*)$") {
                continue
            }

            $Key = $Matches.Key.Trim().ToLowerInvariant()
            $Value = $Matches.Value.Trim()

            switch ($Key) {
                "host" {
                    if (-not $Value) {
                        throw "Global host value is empty in $ConfigPath"
                    }

                    $HostName = $Value
                }
                "port" {
                    $ParsedPort = 0
                    if (-not [int]::TryParse($Value, [ref]$ParsedPort) -or $ParsedPort -lt 1 -or $ParsedPort -gt 65535) {
                        throw "Global port value must be an integer from 1 to 65535 in $ConfigPath`: $Value"
                    }

                    $Port = $ParsedPort
                }
                "api-key" { $ApiKey = $Value }
                "api_key" { $ApiKey = $Value }
                "memory-margin" { $MemoryMargin = $Value }
                "models-memory-margin" { $MemoryMargin = $Value }
                "device" { $Device = $Value }
                "main-gpu" { $Device = $Value }
                "sleep-idle-seconds" {
                    $ParsedSec = 0
                    if ([int]::TryParse($Value, [ref]$ParsedSec) -and $ParsedSec -ge 0) {
                        $SleepIdleSeconds = $ParsedSec
                    }
                }
                "models-max" {
                    $ParsedMax = 0
                    if ([int]::TryParse($Value, [ref]$ParsedMax) -and $ParsedMax -ge 1) {
                        $ModelsMax = $ParsedMax
                    }
                }
            }
        }
    }

    $HealthHost = $HostName
    if ($HealthHost -eq "0.0.0.0") {
        $HealthHost = "127.0.0.1"
    }
    elseif ($HealthHost -eq "::") {
        $HealthHost = "::1"
    }

    if ($HealthHost.Contains(":") -and -not $HealthHost.StartsWith("[")) {
        $HealthHost = "[$HealthHost]"
    }

    return [pscustomobject]@{
        HostName         = $HostName
        Port             = $Port
        BaseUrl          = "http://$HealthHost`:$Port"
        ApiKey           = $ApiKey
        MemoryMargin     = $MemoryMargin
        Device           = $Device
        SleepIdleSeconds = $SleepIdleSeconds
        ModelsMax        = $ModelsMax
    }
}

function Get-LlamaDetectedCudaMajor {
    param([int]$DefaultMajor = 13)

    $NvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($NvidiaSmi) {
        try {
            $Output = (& $NvidiaSmi.Source 2>$null) -join " "
            if ($Output -match "CUDA (?:UMD )?Version:\s*(\d+)") {
                $Detected = [int]$Matches[1]
                if ($Detected -ge 10 -and $Detected -le 20) {
                    return $Detected
                }
            }
        }
        catch {
            # Ignore and return default
        }
    }

    return $DefaultMajor
}

function ConvertTo-LlamaWindowsCommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $Builder = [System.Text.StringBuilder]::new()
    [void]$Builder.Append('"')
    $BackslashCount = 0

    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq '\') {
            $BackslashCount++
            continue
        }

        if ($Character -eq '"') {
            [void]$Builder.Append(('\' * (($BackslashCount * 2) + 1)))
            [void]$Builder.Append('"')
            $BackslashCount = 0
            continue
        }

        if ($BackslashCount -gt 0) {
            [void]$Builder.Append(('\' * $BackslashCount))
            $BackslashCount = 0
        }

        [void]$Builder.Append($Character)
    }

    if ($BackslashCount -gt 0) {
        [void]$Builder.Append(('\' * ($BackslashCount * 2)))
    }

    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function Test-LlamaManagedServerProcess {
    param(
        [object]$Process,
        [string]$CurrentDir,
        [string]$ConfigPath
    )

    if (-not $Process -or $Process.Name -ine "llama-server.exe") {
        return $false
    }

    $CommandLine = [string]$Process.CommandLine
    if ($CommandLine -and $CommandLine.IndexOf($ConfigPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }

    $ExecutablePath = [string]$Process.ExecutablePath
    if (-not $ExecutablePath) {
        return $false
    }

    try {
        $ExpectedRoot = [System.IO.Path]::GetFullPath($CurrentDir).TrimEnd('\')
        $ActualPath = [System.IO.Path]::GetFullPath($ExecutablePath)
        return $ActualPath.StartsWith("$ExpectedRoot\", [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-LlamaScheduledTaskRegistrationMode {
    param(
        [AllowNull()]
        [object]$ExistingTask
    )

    if ($null -eq $ExistingTask) {
        return [pscustomobject]@{
            Result = "Created"
            ShouldForce = $false
        }
    }

    return [pscustomobject]@{
        Result = "Replaced"
        ShouldForce = $true
    }
}

function Get-LlamaGitHubToken {
    param([string]$BaseDir)

    $GitHubToken = $env:GITHUB_TOKEN
    if (-not $GitHubToken) {
        $GitHubToken = $env:GH_TOKEN
    }

    $GitHubTokenFile = Join-Path $BaseDir "llama-config\github-token.txt"
    if (-not $GitHubToken -and (Test-Path $GitHubTokenFile)) {
        $GitHubToken = (Get-Content -Path $GitHubTokenFile -Raw).Trim()
    }

    if (-not $GitHubToken) {
        try {
            $GhCommand = Get-Command gh -ErrorAction SilentlyContinue
            if ($GhCommand) {
                $GitHubToken = (& $GhCommand.Source auth token 2>$null).Trim()
            }
        }
        catch {
            $GitHubToken = $null
        }
    }

    return $GitHubToken
}

function New-LlamaGitHubHeaders {
    param(
        [string]$BaseDir,
        [string]$UserAgent
    )

    $Headers = @{
        "User-Agent"           = $UserAgent
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $GitHubToken = Get-LlamaGitHubToken -BaseDir $BaseDir
    if ($GitHubToken -and $GitHubToken -ne "PASTE_YOUR_GITHUB_TOKEN_HERE") {
        $Headers["Authorization"] = "Bearer $GitHubToken"
    }

    return $Headers
}

function Test-LlamaGitHubTokenConfigured {
    param([hashtable]$Headers)

    return $Headers.ContainsKey("Authorization")
}

function Get-LatestWindowsCudaAssetPair {
    param(
        [object[]]$Assets,
        [int]$CudaMajor
    )

    $RuntimeAssetsByCudaVersion = @{}

    foreach ($Asset in $Assets) {
        if ($Asset.name -match "^cudart-llama-bin-win-cuda-(?<CudaVersion>\d+(?:\.\d+)?)-x64\.zip$") {
            $CudaVersion = [version]$Matches.CudaVersion

            if ($CudaVersion.Major -eq $CudaMajor) {
                $RuntimeAssetsByCudaVersion[$CudaVersion.ToString()] = $Asset
            }
        }
    }

    $MainCandidates = foreach ($Asset in $Assets) {
        if ($Asset.name -match "^llama-b(?<Build>\d+)-bin-win-cuda-(?<CudaVersion>\d+(?:\.\d+)?)-x64\.zip$") {
            $CudaVersion = [version]$Matches.CudaVersion

            if ($CudaVersion.Major -eq $CudaMajor -and $RuntimeAssetsByCudaVersion.ContainsKey($CudaVersion.ToString())) {
                [pscustomobject]@{
                    MainAsset        = $Asset
                    CudaRuntimeAsset = $RuntimeAssetsByCudaVersion[$CudaVersion.ToString()]
                    CudaVersion      = $CudaVersion
                    Build            = [int]$Matches.Build
                }
            }
        }
    }

    $Pair = $MainCandidates |
    Sort-Object -Property CudaVersion, Build -Descending |
    Select-Object -First 1

    if ($Pair) {
        return $Pair
    }

    $AvailableCudaAssets = $Assets |
    Where-Object { $_.name -match "win-cuda|cudart-llama-bin-win-cuda" } |
    Select-Object -ExpandProperty name

    throw "Could not find a matching llama Windows x64 CUDA $CudaMajor.x main zip and CUDA runtime zip in release. Available CUDA assets: $($AvailableCudaAssets -join ', ')"
}

function Invoke-RestMethodWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$Retries = 3
    )

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 60
        }
        catch {
            $Message = $_.Exception.Message
            Write-Warning "Invoke-RestMethod failed, attempt $Attempt/$Retries`: $Message"

            if ($Attempt -ge $Retries) {
                throw
            }

            Start-Sleep -Seconds ([Math]::Min(30, 5 * $Attempt))
        }
    }
}

function Get-LatestLlamaCudaRelease {
    param(
        [hashtable]$Headers,
        [int]$CudaMajor = 13,
        [string]$GitHubApi = "https://api.github.com/repos/ggml-org/llama.cpp/releases"
    )

    # Note: ggml-org/llama.cpp automated build releases (bXXXX) are marked as pre-releases
    # on GitHub. Querying /releases/latest returns only formal non-prerelease tags
    # (e.g. v0.8.0), which lack Windows CUDA release assets. If a /releases/latest URL
    # is passed, we automatically query /releases to discover the latest build release
    # containing matching Windows CUDA assets.
    $ReleasesApi = if ($GitHubApi.EndsWith("/latest")) {
        $GitHubApi.Substring(0, $GitHubApi.Length - 7) + "?per_page=15"
    }
    elseif ($GitHubApi.Contains("?")) {
        $GitHubApi
    }
    else {
        "$GitHubApi`?per_page=15"
    }

    try {
        $Releases = Invoke-RestMethodWithRetry -Uri $ReleasesApi -Headers $Headers
        if ($Releases -isnot [array]) {
            $Releases = @($Releases)
        }

        foreach ($Rel in $Releases) {
            if (-not $Rel.assets) { continue }
            try {
                $Pair = Get-LatestWindowsCudaAssetPair -Assets $Rel.assets -CudaMajor $CudaMajor
                if ($Pair) {
                    return [pscustomobject]@{
                        Release   = $Rel
                        AssetPair = $Pair
                    }
                }
            }
            catch {
                # This release did not have matching CUDA assets for the specified CUDA major, try next
            }
        }
    }
    catch {
        Write-Warning "Failed to query releases list: $($_.Exception.Message)"
    }

    # Fallback to direct URL if /releases failed
    $FallbackRel = Invoke-RestMethodWithRetry -Uri $GitHubApi -Headers $Headers
    $Pair = Get-LatestWindowsCudaAssetPair -Assets $FallbackRel.assets -CudaMajor $CudaMajor
    return [pscustomobject]@{
        Release   = $FallbackRel
        AssetPair = $Pair
    }
}

function Start-LlamaTranscriptWithRotation {
    param(
        [string]$Path,
        [int64]$MaxBytes = 1048576,
        [int]$KeepFiles = 5
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

    Start-Transcript -Path $Path -Append | Out-Null
}

function Get-LlamaCudaBuildNumber {
    param([string]$Name)

    if ($Name -match "^llama-b(?<Build>\d+)-bin-win-cuda-\d+(?:\.\d+)?-x64(?:\.zip)?$") {
        return [int]$Matches.Build
    }

    return 0
}

function Get-LlamaCudaVersionFromName {
    param([string]$Name)

    if ($Name -match "cuda-(?<CudaVersion>\d+(?:\.\d+)?)-x64") {
        return $Matches.CudaVersion
    }

    return $null
}

function Remove-OldLlamaVersionsAndCache {
    param(
        [string]$BaseDir,
        [string]$DownloadCacheDir,
        [string]$ActiveInstallDir,
        [int]$CudaMajor,
        [int]$KeepVersions
    )

    $VersionDirs = Get-ChildItem -Path $BaseDir -Directory |
    Where-Object { $_.Name -match "^llama-b\d+-bin-win-cuda-$CudaMajor(?:\.\d+)?-x64$" } |
    Sort-Object { Get-LlamaCudaBuildNumber -Name $_.Name } -Descending

    $DirsToRemove = $VersionDirs | Select-Object -Skip $KeepVersions

    foreach ($Dir in $DirsToRemove) {
        if ($Dir.FullName -ne $ActiveInstallDir) {
            Write-Host "Removing old version: $($Dir.FullName)"
            Remove-Item $Dir.FullName -Recurse -Force
        }
    }

    $BuildsToKeep = $VersionDirs |
    Select-Object -First $KeepVersions |
    ForEach-Object { Get-LlamaCudaBuildNumber -Name $_.Name }

    $CudaVersionsToKeep = $VersionDirs |
    Select-Object -First $KeepVersions |
    ForEach-Object { Get-LlamaCudaVersionFromName -Name $_.Name } |
    Where-Object { $_ } |
    Select-Object -Unique

    $CachedZips = Get-ChildItem -Path $DownloadCacheDir -File |
    Where-Object {
        $_.Name -match "^llama-b\d+-bin-win-cuda-$CudaMajor(?:\.\d+)?-x64\.zip$" -or
        $_.Name -match "^cudart-llama-bin-win-cuda-$CudaMajor(?:\.\d+)?-x64\.zip$"
    } |
    Sort-Object {
        if ($_.Name -match "^llama-b\d+-") {
            Get-LlamaCudaBuildNumber -Name $_.Name
        }
        else {
            [int]::MaxValue
        }
    } -Descending

    foreach ($Zip in $CachedZips) {
        $ShouldKeep = $false

        if ($Zip.Name -match "^llama-b\d+-") {
            $ShouldKeep = (Get-LlamaCudaBuildNumber -Name $Zip.Name) -in $BuildsToKeep
        }
        elseif ($Zip.Name -match "^cudart-llama-bin-win-cuda-\d+(?:\.\d+)?-x64\.zip$") {
            $ShouldKeep = (Get-LlamaCudaVersionFromName -Name $Zip.Name) -in $CudaVersionsToKeep
        }

        if (-not $ShouldKeep) {
            Write-Host "Removing old cached zip: $($Zip.FullName)"
            Remove-Item $Zip.FullName -Force
        }
    }
}
