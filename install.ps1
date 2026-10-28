# Ставит или обновляет всю сборку euf (NeoForge 1.21.1) в папку mods TLauncher:
# Все моды из modpack.json для NeoForge 1.21.1. Лишние старые версии этих модов убирает.
# Запуск: двойной клик по install-modpack.bat (лежит рядом).
#   -TestProfile      только %APPDATA%\.minecraft\versions\test\mods
#   -Stable           брать стабильные релизы наших модов (v*), а не свежие dev-сборки
#   -VersionName "…"  имя версии в TLauncher (по умолчанию "NeoForge 1.21.1")
#   -GameDir "…"      папка игры (по умолчанию %APPDATA%\.minecraft-codex-neoforge-1.21.1)
param(
    [switch]$Stable,
    [switch]$TestProfile,
    [string]$VersionName = 'NeoForge 1.21.1',
    [string]$GameDir = (Join-Path $env:APPDATA '.minecraft-codex-neoforge-1.21.1')
)

$ErrorActionPreference = 'Stop'

# Explicitly select the user's dedicated TLauncher test profile, never the shared mods directory.
if ($TestProfile) {
    if ($PSBoundParameters.ContainsKey('GameDir') -or $PSBoundParameters.ContainsKey('VersionName')) {
        throw 'Use -TestProfile by itself; its target is fixed to .minecraft/versions/test/mods.'
    }
    $GameDir = Join-Path $env:APPDATA '.minecraft'
    $VersionName = 'test'
}
# Allowed roots are fixed; selecting the shared root requires the explicit test-profile mode.
$isolatedRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA '.minecraft-codex-neoforge-1.21.1')).TrimEnd('\', '/')
if ($TestProfile) { $isolatedRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA '.minecraft')).TrimEnd('\', '/') }
if ([IO.Path]::GetFullPath($GameDir).TrimEnd('\', '/') -ine $isolatedRoot) {
    throw 'Use only %APPDATA%\.minecraft-codex-neoforge-1.21.1. The original Minecraft directory is protected.'
}
function Assert-IsolatedPath([string]$path) {
    $item = [IO.Path]::GetFullPath($path)
    while ($item) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked directories are not allowed: $item"
        }
        $parent = Split-Path -Parent $item
        if ($parent -eq $item) { break }
        $item = $parent
    }
}
Assert-IsolatedPath $GameDir

# Normalize launcher arrays, conditional value objects and TLauncher argument maps.
function Get-LaunchArguments($node) {
    if ($null -eq $node) { return }
    if ($node -is [string]) {
        $text = $node.Trim()
        if ($text.StartsWith('{') -or $text.StartsWith('[')) {
            try { $decoded = $text | ConvertFrom-Json } catch { $decoded = $null }
            if ($null -ne $decoded) { Get-LaunchArguments $decoded; return }
        }
        $node
        return
    }
    if ($node -is [array]) {
        foreach ($entry in $node) { Get-LaunchArguments $entry }
        return
    }
    if ($node -is [pscustomobject]) {
        # Typed/conditional arguments carry metadata beside value; metadata is not a token.
        $valueProperty = $node.PSObject.Properties['value']
        if (-not $valueProperty) { $valueProperty = $node.PSObject.Properties['values'] }
        if ($valueProperty) {
            foreach ($key in @('name', 'key')) {
                $label = $node.PSObject.Properties[$key]
                if ($label -and $label.Value -is [string] -and $label.Value.StartsWith('--')) { $label.Value }
            }
            Get-LaunchArguments $valueProperty.Value
            return
        }
        foreach ($property in $node.PSObject.Properties) {
            if ($property.Name -eq 'rules') { continue }
            if ($property.Name.StartsWith('--')) { $property.Name }
            Get-LaunchArguments $property.Value
        }
    }
}

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PackRepo = 'stardely62-oss/euf-modpack-codex'
$Headers = @{ 'User-Agent' = 'euf-modpack-installer' }

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

# Свежий список модов из репозитория сборки; без интернета до GitHub — тот, что лежит рядом
function Get-Manifest {
    try {
        return Invoke-RestMethod "https://raw.githubusercontent.com/$PackRepo/main/modpack-neoforge-1.21.1.json" -Headers $Headers
    } catch {
        $local = Join-Path $PSScriptRoot 'modpack-neoforge-1.21.1.json'
        if (Test-Path $local) { return Get-Content $local -Raw -Encoding UTF8 | ConvertFrom-Json }
        throw "Не удалось получить список модов сборки."
    }
}

function Remove-Old($mods, $patterns, $keep) {
    foreach ($pattern in $patterns) {
        Get-ChildItem $mods -Filter $pattern | Where-Object { $_.Name -ne $keep } | Remove-Item -Force
    }
}

try {
    Say "== Сборка euf: установка и обновление ==" Cyan

    # 1. Папка mods: отдельная у версии, если TLauncher так настроен, иначе общая
    $versionDir = Join-Path $GameDir "versions\$VersionName"
    if (-not (Test-Path $versionDir)) {
        throw "Не нашёл версию '$VersionName' в $GameDir\versions. Установи её в TLauncher и запусти один раз."
    }
    $mods = Join-Path $versionDir 'mods'
    if (-not $TestProfile -and -not (Test-Path $mods)) { $mods = Join-Path $GameDir 'mods' }
    Assert-IsolatedPath $mods
    Say "Папка модов: $mods"

    if (Get-Process -Name javaw, java -ErrorAction SilentlyContinue) {
        throw "Close Minecraft before updating mods."
    }

    # Confirm a NeoForge 1.21.1 profile before touching any installed mods.
    $profile = Join-Path $versionDir "$VersionName.json"
    if (-not (Test-Path -LiteralPath $profile)) { throw "Missing launcher profile: $profile" }
    # TLauncher may keep NeoForge libraries in the profile's inheritsFrom parent.
    $loader = $null
    $seenProfiles = @{}
    for ($depth = 0; $depth -lt 8; $depth++) {
        Assert-IsolatedPath $profile
        if ($seenProfiles.ContainsKey($profile)) { throw 'Cyclic launcher profile inheritance.' }
        $seenProfiles[$profile] = $true
        $profileText = Get-Content -LiteralPath $profile -Raw
        $profileData = $profileText | ConvertFrom-Json
        # Official NeoForge profiles carry the loader version as a launch argument,
        # not necessarily as a net.neoforged:neoforge library.
        $gameArguments = @(Get-LaunchArguments $profileData.arguments)
        for ($i = 0; $i -lt $gameArguments.Count; $i++) {
            $argument = $gameArguments[$i]
            if ($argument -isnot [string]) { continue }
            if ($argument -eq '--fml.neoForgeVersion' -and $i + 1 -lt $gameArguments.Count) {
                $value = [string]$gameArguments[$i + 1]
                if ($value -match '^([0-9]+\.[0-9]+\.[0-9]+)(?:-.*)?$') { $loader = [version]$Matches[1] }
            } elseif ($argument -match '(?:^|\s)--fml\.neoForgeVersion[=\s]+([0-9]+\.[0-9]+\.[0-9]+)(?:-[\w.]+)?(?:\s|$)') {
                $loader = [version]$Matches[1]
            }
        }
        if (-not $loader -and $profileData.minecraftArguments -match '(?:^|\s)--fml\.neoForgeVersion[=\s]+([0-9]+\.[0-9]+\.[0-9]+)') {
            $loader = [version]$Matches[1]
        }
        if (-not $loader -and $profileData.libraries) {
            $loaderMatch = [regex]::Match([string]($profileData.libraries | ConvertTo-Json -Depth 20 -Compress), 'net\.neoforged:neoforge:([0-9]+\.[0-9]+\.[0-9]+)')
            if ($loaderMatch.Success) { $loader = [version]$loaderMatch.Groups[1].Value }
        }
        if ($loader) { break }
        $parent = $profileData.inheritsFrom
        if (-not $parent) { break }
        if ($parent -in @('.', '..') -or $parent.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $parent.Contains('/') -or $parent.Contains('\')) {
            throw 'Invalid inherited profile name.'
        }
        $profile = Join-Path (Join-Path $GameDir "versions\$parent") "$parent.json"
        if (-not (Test-Path -LiteralPath $profile)) { throw "Missing inherited profile: $parent" }
    }
    if (-not $loader -or $loader.Major -ne 21 -or $loader.Minor -ne 1) { throw 'NeoForge for Minecraft 1.21.1 was not found in the selected profile or its parent profiles.' }
    if ($loader -lt [version]'21.1.264') { throw "Detected NeoForge $loader. These mods require NeoForge 21.1.264 or newer for Minecraft 1.21.1. Update the loader for profile '$VersionName'." }
    Say "NeoForge $loader"
    if ((Test-Path -LiteralPath $mods) -and (Get-ChildItem -LiteralPath $mods -Filter 'fabric-api-*.jar')) { throw 'This folder contains Fabric mods. Use a clean NeoForge profile.' }

    New-Item -ItemType Directory -Force -Path $mods | Out-Null

    # 3. Моды сборки
    $manifest = Get-Manifest
    if (-not $manifest -or $manifest.minecraft -ne '1.21.1' -or $manifest.loader -ne 'neoforge' -or -not $manifest.mods) {
        throw 'Invalid or empty manifest: expected Minecraft 1.21.1 / NeoForge. No mods were updated.'
    }
    foreach ($mod in $manifest.mods) {
        if ($mod.github) {
            # Наш мод: свежая dev-сборка или последний стабильный релиз из GitHub Releases
            $api = if ($Stable) { "https://api.github.com/repos/$($mod.github)/releases/latest" } else { "https://api.github.com/repos/$($mod.github)/releases/tags/neoforge-dev" }
            $release = Invoke-RestMethod $api -Headers $Headers
            $asset = $release.assets | Where-Object { $_.name -like $mod.asset -and $_.name -notlike '*-sources*' } | Select-Object -First 1
            if (-not $asset) { throw "$($mod.name): в релизе '$($release.name)' нет jar-файла." }
            $name = $asset.name
            $url = $asset.browser_download_url
            $sha = $null
        } else {
            # Чужой мод: точная версия с Modrinth, сверяем контрольную сумму
            $name = $mod.file
            $url = $mod.url
            $sha = $mod.sha512
        }
        if (Test-Path (Join-Path $mods $name)) {
            Say "$($mod.name): уже последней версии ($name)" Green
            Remove-Old $mods $mod.replaces $name
            continue
        }
        $tmp = Join-Path $env:TEMP $name
        Invoke-WebRequest $url -OutFile $tmp -Headers $Headers -UseBasicParsing
        if ($sha -and ((Get-FileHash $tmp -Algorithm SHA512).Hash.ToLower() -ne $sha.ToLower())) {
            Remove-Item $tmp -Force
            throw "$($mod.name): файл скачался повреждённым (контрольная сумма не совпала). Попробуй ещё раз."
        }
        Remove-Old $mods $mod.replaces $name
        Move-Item $tmp (Join-Path $mods $name) -Force
        Say "$($mod.name): установлен $name" Green
    }

    Say ""
    Say "Готово! Запускай в TLauncher версию '$VersionName'." Cyan
}
catch {
    Say ""
    Say "Ошибка: $($_.Exception.Message)" Red
    exit 1
}
