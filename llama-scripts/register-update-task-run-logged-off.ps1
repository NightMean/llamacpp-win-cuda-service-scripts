param(
    [string]$TaskName = "Update llama.cpp CUDA 13.x and restart server",
    [string]$BaseDir = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 365)]
    [int]$DaysInterval = 3,
    [string]$At = "08:00"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "llama-common.ps1")

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
$IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$TaskUserId = $Identity.Name

if (-not $IsAdmin) {
    throw "Please run this script from an elevated PowerShell window: Run as administrator."
}

$ScriptPath = Join-Path $BaseDir "llama-scripts\update-llamacpp-cuda13.ps1"
if (-not (Test-Path $ScriptPath)) {
    throw "Update script not found: $ScriptPath"
}

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
    -WorkingDirectory $BaseDir

$Trigger = New-ScheduledTaskTrigger `
    -Daily `
    -DaysInterval $DaysInterval `
    -At $At

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries:$false `
    -DontStopIfGoingOnBatteries:$false `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$TaskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $TaskUserId `
    -LogonType S4U `
    -RunLevel Highest

$TaskPath = "\"
$ExistingTask = Get-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath $TaskPath `
    -ErrorAction SilentlyContinue

$RegisterParams = @{
    TaskName = $TaskName
    TaskPath = $TaskPath
    Action = $Action
    Trigger = $Trigger
    Settings = $Settings
    Principal = $TaskPrincipal
    Description = "Update llama.cpp Windows CUDA 13.x build and restart llama-server, even when the user is not logged on."
}

$RegistrationMode = Get-LlamaScheduledTaskRegistrationMode -ExistingTask $ExistingTask
if ($RegistrationMode.ShouldForce) {
    $RegisterParams.Force = $true
}

Register-ScheduledTask @RegisterParams | Out-Null
Write-Host "$($RegistrationMode.Result) scheduled task: $TaskPath$TaskName"

Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Format-List TaskName,State,Principal,Actions,Triggers
Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath | Format-List LastRunTime,LastTaskResult,NextRunTime
