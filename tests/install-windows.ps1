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
function Run-Installer {
    param([switch]$TestProfile)
    $global:LASTEXITCODE = 0
    & $installer -TestProfile:$TestProfile
    if ($LASTEXITCODE -ne 0) { throw "Installer failed with exit code $LASTEXITCODE" }
}
Run-Installer
Run-Installer # Updating the same release must preserve unrelated files too.
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

# The user's existing profile lives under .minecraft/versions/test.
$testProfile = Join-Path $env:APPDATA '.minecraft\versions\test'
$otherProfile = Join-Path $env:APPDATA '.minecraft\versions\claude\mods'
New-Item -ItemType Directory -Force $testProfile, $otherProfile | Out-Null
Set-Content (Join-Path $testProfile 'test.json') '{"libraries":[{"name":"net.neoforged:neoforge:21.1.265"}]}'
Set-Content (Join-Path $otherProfile 'claude-profile.jar') 'other profile'
# Deliberately do not create test/mods: no fallback into the shared mods is allowed.
Run-Installer -TestProfile
Run-Installer -TestProfile
$testMods = Join-Path $testProfile 'mods'
if (-not (Test-Path (Join-Path $testMods 'mages-legacy-0.2.0-fixture.jar'))) { throw 'Test profile was not updated' }
if ((Get-ChildItem -LiteralPath $original).Count -ne 1) { throw 'Shared mods directory was modified' }
if ((Get-Content (Join-Path $original 'claude-sentinel.jar') -Raw).Trim() -ne 'original installation') { throw 'Shared mod was changed' }
if ((Get-Content (Join-Path $otherProfile 'claude-profile.jar') -Raw).Trim() -ne 'other profile') { throw 'Other profile was changed' }
Write-Host 'PASS: test profile install/update creates only test/mods, preserving shared mods and other profiles.'

# An inherited loader may be read, but the parent profile must never receive our mods.
$parentProfile = Join-Path $env:APPDATA '.minecraft\versions\neo-base'
New-Item -ItemType Directory -Force $parentProfile | Out-Null
Set-Content (Join-Path $parentProfile 'neo-base.json') '{"libraries":[{"name":"net.neoforged:neoforge:21.1.265"}]}'
Set-Content (Join-Path $testProfile 'test.json') '{"id":"test","inheritsFrom":"neo-base"}'
Run-Installer -TestProfile
if (Test-Path (Join-Path $parentProfile 'mods')) { throw 'Inherited profile was modified' }
Write-Host 'PASS: inherited NeoForge profile is detected without modifying the parent.'

# Regression: the real official NeoForge installer profile has no neoforge library.
$official = Join-Path $PSScriptRoot 'fixtures\neoforge-21.1.265-version.json'
Copy-Item $official (Join-Path $testProfile 'test.json') -Force
Run-Installer -TestProfile
# Also resolve the actual profile through a TLauncher wrapper.
Copy-Item $official (Join-Path $parentProfile 'neo-base.json') -Force
Set-Content (Join-Path $testProfile 'test.json') '{"id":"test","inheritsFrom":"neo-base"}'
Run-Installer -TestProfile
# Legacy string arguments remain supported.
Set-Content (Join-Path $testProfile 'test.json') '{"id":"test","minecraftArguments":"--fml.neoForgeVersion 21.1.265 --fml.mcVersion 1.21.1"}'
Run-Installer -TestProfile
if ((Get-ChildItem -LiteralPath $original).Count -ne 1 -or (Test-Path (Join-Path $parentProfile 'mods'))) { throw 'Profile isolation was broken' }
Write-Host 'PASS: official NeoForge launch arguments, inherited official profile and legacy argument string.'

# Both normal double-click entry points must select the agreed test profile.
foreach ($entry in @('install-modpack.bat', 'install-test.bat')) {
    $command = Get-Content (Join-Path $PSScriptRoot "..\$entry") -Raw
    if ($command -notmatch 'install\.ps1"\s+-TestProfile(?:\s|$)') { throw "$entry does not select the test profile" }
}
Write-Host 'PASS: default and test batch entry points target .minecraft/versions/test/mods.'

# TLauncher may wrap launch arguments in conditional values or maps.
$nested = '{"id":"test","mainClass":"cpw.mods.bootstraplauncher.BootstrapLauncher","arguments":{"game":[{"rules":[{"action":"allow"}],"value":["--fml.neoForgeVersion","21.1.264","--fml.mcVersion","1.21.1"]}]}}'
Set-Content (Join-Path $testProfile 'test.json') $nested
Run-Installer -TestProfile
Set-Content (Join-Path $testProfile 'test.json') '{"id":"test","arguments":{"game":{"--fml.neoForgeVersion":"21.1.264","--fml.mcVersion":"1.21.1"}}}'
Run-Installer -TestProfile
$encoded = @{ id = 'test'; arguments = ($nested | ConvertFrom-Json).arguments | ConvertTo-Json -Depth 10 -Compress } | ConvertTo-Json -Depth 10
Set-Content (Join-Path $testProfile 'test.json') $encoded
Run-Installer -TestProfile
Write-Host 'PASS: NeoForge 21.1.264 nested, mapped and JSON-encoded launcher arguments.'
