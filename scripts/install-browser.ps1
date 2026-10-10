param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'AIWorkBrowser'))
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.6.1') { throw 'PowerShell 7.6.1+ required' }
if (Get-Command ai-browser-launch -ErrorAction SilentlyContinue) {
    Write-Output 'Existing ai-browser-launch found. Keep its registered configuration; no files changed.'
    exit 0
}
if (-not (Get-Command cdp-launch -ErrorAction SilentlyContinue)) { throw 'Install cdp-tools first (see README).' }
$target = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $target) { throw 'Destination exists; review it manually instead of overwriting.' }
$source = Join-Path $PSScriptRoot '../browser-launcher'
[void](New-Item -ItemType Directory -Path $target)
foreach ($name in @('ai-browser-launch.ps1','ai-browser-engine.ps1','ai-browser-leases.ps1')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $target $name)
}
$profiles = Join-Path $target 'profiles'
$config = @{
    schemaVersion = 2; defaultInstance = 'main'; displayName = 'AI Work Browser'
    profileName = 'ai-work-main'; profileRoot = $profiles
    profileDir = (Join-Path $profiles 'ai-work-main'); port = 9232
    cdpUrl = 'http://127.0.0.1:9232'; defaultUrl = 'about:blank'
    allowExtensions = $true; requireExistingProfile = $true
    allocation = @{ pool = @('01','02'); leaseSeconds = 900; heartbeatSeconds = 60 }
    instances = @{
        main = @{ displayName = 'AI Work Browser Main'; profileName = 'ai-work-main'; port = 9232 }
        '01' = @{ displayName = 'AI Work Browser 01'; profileName = 'ai-work-01'; port = 9233 }
        '02' = @{ displayName = 'AI Work Browser 02'; profileName = 'ai-work-02'; port = 9234 }
    }
}
foreach ($name in @('ai-work-main','ai-work-01','ai-work-02')) {
    [void](New-Item -ItemType Directory -Path (Join-Path $profiles $name))
}
[IO.File]::WriteAllText((Join-Path $target 'ai-browser-config.json'), ($config | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$bin = Join-Path $target 'bin'
[void](New-Item -ItemType Directory -Path $bin)
$launcher = (Join-Path $target 'ai-browser-launch.ps1').Replace("'", "''")
$wrapper = "& '$launcher' @args`nexit `$LASTEXITCODE`n"
[IO.File]::WriteAllText((Join-Path $bin 'ai-browser-launch.ps1'), $wrapper, [Text.UTF8Encoding]::new($false))
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($bin -notin ($userPath -split ';')) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$bin", 'User')
}
$env:PATH += ";$bin"
Write-Output "Installed registered launcher at $target. Restart terminal and AI app to refresh PATH."
