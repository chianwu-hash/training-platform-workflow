param(
    [ValidateSet('Acquire','Heartbeat','Release')][string]$Action,
    [ValidateSet('main','01','02')][string]$Instance,
    [string]$Owner,
    [string]$LeaseId,
    [int]$WorkerProcessId = 0
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.6.1') { throw 'PowerShell 7.6.1+ required' }
if (-not (Get-Command ai-browser-launch -ErrorAction SilentlyContinue)) { throw 'ai-browser-launch is not installed' }
$leaseArgs = @{ Json = $true; Owner = $Owner }
switch ($Action) {
    'Acquire' { $leaseArgs.Acquire = $true; $leaseArgs.Instance = $Instance }
    'Heartbeat' {
        $leaseArgs.Heartbeat = $true; $leaseArgs.LeaseId = $LeaseId
        if ($WorkerProcessId -gt 0) { $leaseArgs.WorkerProcessId = $WorkerProcessId }
    }
    'Release' { $leaseArgs.Release = $true; $leaseArgs.LeaseId = $LeaseId }
}
ai-browser-launch @leaseArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
