param(
  [string]$WowRoot = "",
  [string]$Flavor = ""
)
# Установка аддона «Летопись Орды»: копирует папку HordeChronicle в <клиент>\Interface\AddOns.
# Повторный запуск обновляет аддон и не трогает уже написанные сказания (Sagas.lua).
$ErrorActionPreference = "Stop"
$Project = Split-Path -Parent $PSScriptRoot
$AddonSrc = Join-Path $Project "HordeChronicle"

function Find-WowRoots {
  $found = @()
  foreach ($key in @("HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft", "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft")) {
    try { $p = (Get-ItemProperty $key -ErrorAction Stop).InstallPath; if ($p) { $found += (Split-Path -Parent ($p.TrimEnd("\"))) } } catch {}
  }
  foreach ($d in @("C:\Program Files (x86)\World of Warcraft", "C:\Program Files\World of Warcraft", "D:\World of Warcraft", "D:\Games\World of Warcraft", "E:\World of Warcraft", "C:\Games\World of Warcraft")) {
    if (Test-Path $d) { $found += $d }
  }
  return $found | Where-Object { Test-Path $_ } | Select-Object -Unique
}

if (-not $WowRoot) {
  $roots = @(Find-WowRoots)
  if ($roots.Count -ge 1) { $WowRoot = $roots[0] }
  else { $WowRoot = Read-Host "Не нашёл World of Warcraft. Вставьте путь к папке игры (например D:\World of Warcraft)" }
}
if (-not (Test-Path $WowRoot)) { Write-Host "Папка не найдена: $WowRoot" -ForegroundColor Red; exit 1 }

# Клиенты лежат в подпапках вида _retail_, _classic_, _classic_beta_ (тест Forever), к релизу может появиться _forever_
$flavors = @(Get-ChildItem $WowRoot -Directory | Where-Object { $_.Name -match '^_.+_$' } | Sort-Object @{ Expression = {
  if ($_.Name -match 'forever') { 0 } elseif ($_.Name -eq '_classic_beta_') { 1 } else { 2 } } }, Name)
if ($flavors.Count -eq 0) { Write-Host "В $WowRoot нет папок клиентов (_retail_, _classic_beta_ …). Запустите игру один раз и повторите." -ForegroundColor Red; exit 1 }

if ($Flavor) { $chosen = $flavors | Where-Object { $_.Name -eq $Flavor } | Select-Object -First 1 }
elseif ($flavors.Count -eq 1) { $chosen = $flavors[0] }
else {
  Write-Host "Нашёл несколько клиентов WoW:"
  for ($i = 0; $i -lt $flavors.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $flavors[$i].Name) }
  $ans = Read-Host "Номер клиента WoW Forever (Enter — 1)"
  if (-not $ans) { $ans = "1" }
  $chosen = $flavors[[int]$ans - 1]
}
if (-not $chosen) { Write-Host "Клиент не выбран." -ForegroundColor Red; exit 1 }

$addons = Join-Path $chosen.FullName "Interface\AddOns"
New-Item -ItemType Directory -Force -Path $addons | Out-Null
$target = Join-Path $addons "HordeChronicle"
if (Test-Path $target) {
  $item = Get-Item $target -Force
  if ($item.LinkType -eq "Junction" -or $item.LinkType -eq "SymbolicLink") {
    # старая установка ссылкой: убираем только саму ссылку, файлы проекта не трогаем
    [System.IO.Directory]::Delete($target, $false)
  }
}
New-Item -ItemType Directory -Force -Path $target | Out-Null
$kept = $false
foreach ($f in Get-ChildItem $AddonSrc -File) {
  $dest = Join-Path $target $f.Name
  if ($f.Name -eq "Sagas.lua" -and (Test-Path $dest)) { $kept = $true; continue }   # сказания игрока не затираем
  Copy-Item $f.FullName $dest -Force
}

[IO.File]::WriteAllText((Join-Path $Project "wow_path.txt"), $chosen.FullName, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "Готово: «Летопись Орды» скопирована в $target" -ForegroundColor Green
if ($kept) { Write-Host "Уже написанные сказания сохранены." }
Write-Host "В игре: /летопись диаг — проверка, /летопись тест — пробная победа, /летопись — книга."
