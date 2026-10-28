# Ставит или обновляет всю сборку euf (NeoForge 1.21.1) в папку mods TLauncher:
# Все моды из modpack.json для NeoForge 1.21.1. Лишние старые версии этих модов убирает.
# Запуск: двойной клик по install-modpack.bat (лежит рядом).
#   -Stable           брать стабильные релизы наших модов (v*), а не свежие dev-сборки
#   -VersionName "…"  имя версии в TLauncher (по умолчанию "Fabric 1.20.1")
#   -GameDir "…"      папка игры (по умолчанию %APPDATA%\.minecraft-codex-neoforge-1.21.1)
param(
    [switch]$Stable,
    [string]$VersionName = 'NeoForge 1.21.1',
    [string]$GameDir = (Join-Path $env:APPDATA '.minecraft-codex-neoforge-1.21.1')
)

$ErrorActionPreference = 'Stop'

# This installer exclusively owns a separate game directory.
$isolatedRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA '.minecraft-codex-neoforge-1.21.1')).TrimEnd('\', '/')
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

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PackRepo = 'stardely62-oss/euf-modpack-codex'
$Headers = @{ 'User-Agent' = 'euf-modpack-installer' }

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

# Свежий список модов из репозитория сборки; без интернета до GitHub — тот, что лежит рядом
function Get-Manifest {
    try {
        return Invoke-RestMethod "https://raw.githubusercontent.com/$PackRepo/main/modpack.json" -Headers $Headers
    } catch {
        $local = Join-Path $PSScriptRoot 'modpack.json'
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
    if (-not (Test-Path $mods)) { $mods = Join-Path $GameDir 'mods' }
    Assert-IsolatedPath $mods
    New-Item -ItemType Directory -Force -Path $mods | Out-Null
    Say "Папка модов: $mods"

    if (Get-Process -Name javaw, java -ErrorAction SilentlyContinue) {
        throw "Close Minecraft before updating mods."
    }

    # Confirm a NeoForge 1.21.1 profile before touching any installed mods.
    $profile = Join-Path $versionDir "$VersionName.json"
    if (-not (Test-Path -LiteralPath $profile)) { throw "Missing launcher profile: $profile" }
    $profileText = Get-Content -LiteralPath $profile -Raw
    $loaderMatch = [regex]::Match($profileText, 'net\.neoforged:neoforge:(21\.1\.[0-9]+)')
    if (-not $loaderMatch.Success) { throw 'Choose a NeoForge 1.21.1 profile in the separate game directory.' }
    if ([version]$loaderMatch.Groups[1].Value -lt [version]'21.1.265') { throw 'NeoForge 21.1.265 or newer for Minecraft 1.21.1 is required.' }
    if (Get-ChildItem -LiteralPath $mods -Filter 'fabric-api-*.jar') { throw 'This folder contains Fabric mods. Use a clean NeoForge profile.' }

    # 3. Моды сборки
    $manifest = Get-Manifest
    foreach ($mod in $manifest.mods) {
        if ($mod.github) {
            # Наш мод: свежая dev-сборка или последний стабильный релиз из GitHub Releases
            $api = if ($Stable) { "https://api.github.com/repos/$($mod.github)/releases/latest" } else { "https://api.github.com/repos/$($mod.github)/releases/tags/dev" }
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
