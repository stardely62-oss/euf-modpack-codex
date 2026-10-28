# Run the real installer with local network fixtures under Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$env:APPDATA = Join-Path $env:RUNNER_TEMP 'codex-installer-fixture'
$native = Join-Path $env:APPDATA '.minecraft-codex-neoforge-1.21.1'
$original = Join-Path $env:APPDATA '.minecraft\mods'
$profile = Join-Path $native 'versions\NeoForge 1.21.1'
$mods = Join-Path $native 'mods'
New-Item -ItemType Directory -Force $original, $profile, $mods | Out-Null
Set-Content (Join-Path $original 'claude-sentinel.jar') 'original installation'
Set-Content (Join-Path $mods 'keep-unrelated.jar') 'unrelated mod'
Set-Content (Join-Path $mods 'ender-obelisks-old.jar') 'old isolated obelisk'
Set-Content (Join-Path $mods 'mages-legacy-old.jar') 'old isolated races'
Set-Content (Join-Path $profile 'NeoForge 1.21.1.json') '{"libraries":[{"name":"net.neoforged:neoforge:21.1.265"}]}'
$global:CodexFixturePayload = [Text.Encoding]::UTF8.GetBytes('isolated-download-fixture')
$sha = [Security.Cryptography.SHA512]::Create()
$global:CodexFixtureChecksum = ([BitConverter]::ToString($sha.ComputeHash($global:CodexFixturePayload))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()
$global:CodexFixtureManifest = Get-Content (Join-Path $PSScriptRoot '..\modpack-neoforge-1.21.1.json') -Raw | ConvertFrom-Json
foreach ($mod in $global:CodexFixtureManifest.mods) {
    if (-not $mod.github) { $mod.sha512 = $global:CodexFixtureChecksum; $mod.url = 'https://fixtures.invalid/journeymap.jar' }
}
function Get-Process {
    [CmdletBinding()] param($Name)
    # No game is running in the fixture.
}
function Invoke-RestMethod {
    param([string]$Uri, $Headers)
    if ($Uri -like '*raw.githubusercontent.com*') { return $global:CodexFixtureManifest }
    $name = if ($Uri -like '*/modhyed-codex/*') { 'ender-obelisks-0.2.0-fixture.jar' } else { 'mages-legacy-0.2.0-fixture.jar' }
    return [pscustomobject]@{ name = 'fixture'; assets = @([pscustomobject]@{name=$name; browser_download_url="https://fixtures.invalid/$name"}) }
}
function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, $Headers, [switch]$UseBasicParsing)
    [IO.File]::WriteAllBytes($OutFile, $global:CodexFixturePayload)
}
$installer = Join-Path $PSScriptRoot '..\install.ps1'
& $installer
& $installer # Updating the same release must preserve unrelated files too.
foreach ($name in @('ender-obelisks-0.2.0-fixture.jar', 'mages-legacy-0.2.0-fixture.jar', 'journeymap-neoforge-1.21.1-6.0.9.jar', 'keep-unrelated.jar')) {
    if (-not (Test-Path (Join-Path $mods $name))) { throw "Missing isolated file: $name" }
}
if (Test-Path (Join-Path $mods '*-old.jar')) { throw 'Old isolated mods were not replaced' }
if ((Get-Content (Join-Path $original 'claude-sentinel.jar') -Raw).Trim() -ne 'original installation') { throw 'Original game was modified' }
$rejected = $false
try { & $installer -GameDir (Join-Path $env:APPDATA '.minecraft') } catch {
    if ($_.Exception.Message -notlike 'Use only *') { throw }
    $rejected = $true
}
if (-not $rejected) { throw 'Original game directory was accepted' }
Write-Host 'PASS: Windows install, repeated update, checksum, unrelated files, original game isolation.'
