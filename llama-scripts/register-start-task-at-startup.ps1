param(
    [string]$TaskName = "Start llama.cpp server",
    [string]$BaseDir = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(0, 3600)]
    [int]$DelaySeconds = 30
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

$ScriptPath = Join-Path $BaseDir "llama-scripts\start-llamacpp-server.ps1"
if (-not (Test-Path $ScriptPath)) {
    throw "Start script not found: $ScriptPath"
}

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
    -WorkingDirectory $BaseDir

$Trigger = New-ScheduledTaskTrigger -AtStartup
if ($DelaySeconds -gt 0) {
    $Trigger.Delay = [System.Xml.XmlConvert]::ToString([TimeSpan]::FromSeconds($DelaySeconds))
}

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

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
    Description = "Start llama-server when Windows starts, even when the user is not logged on."
}

$RegistrationMode = Get-LlamaScheduledTaskRegistrationMode -ExistingTask $ExistingTask
if ($RegistrationMode.ShouldForce) {
    $RegisterParams.Force = $true
}

Register-ScheduledTask @RegisterParams | Out-Null
Write-Host "$($RegistrationMode.Result) scheduled task: $TaskPath$TaskName"

Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Format-List TaskName,State,Principal,Actions,Triggers
Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath | Format-List LastRunTime,LastTaskResult,NextRunTime
