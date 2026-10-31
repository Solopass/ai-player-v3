# Runs a Factorio save on a local headless server with RCON, for the bridge.
# The normal game window ignores --rcon-* even when hosting, so the bridge can
# only talk to a dedicated server. Join it from the game: Multiplayer ->
# Connect to address -> 127.0.0.1
#
#   .\start-server.ps1                     # newest save in %APPDATA%\Factorio\saves
#   .\start-server.ps1 -Save "my save"     # a save by name
#   .\start-server.ps1 -FactorioExe "D:\Games\Factorio\bin\x64\factorio.exe"
param([string]$Save = "", [string]$FactorioExe = "")

$ErrorActionPreference = "Stop"
$client  = Join-Path $env:APPDATA "Factorio"
$server  = Join-Path $env:APPDATA "Factorio-server"   # own write-data: the game window locks its own
$envFile = Join-Path $PSScriptRoot "bridge\.env"

# RCON settings come from bridge/.env so the password lives in one place.
$cfg = @{}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}

# factorio.exe: -FactorioExe, else FACTORIO_EXE in bridge/.env, else every
# Steam library (libraryfolders.vdf), else the standalone default install.
function Find-Factorio {
    $tail = "steamapps\common\Factorio\bin\x64\factorio.exe"
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            $libs += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' |
                     ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
        }
    }
    foreach ($lib in $libs) {
        $p = Join-Path $lib $tail
        if (Test-Path $p) { return $p }
    }
    $standalone = Join-Path $env:ProgramFiles "Factorio\bin\x64\factorio.exe"
    if (Test-Path $standalone) { return $standalone }
    return $null
}
$exe = if ($FactorioExe) { $FactorioExe } elseif ($cfg.FACTORIO_EXE) { $cfg.FACTORIO_EXE } else { Find-Factorio }
if (-not $exe -or -not (Test-Path $exe)) {
    throw "factorio.exe not found - pass -FactorioExe or set FACTORIO_EXE in bridge\.env"
}
$rconPort = if ($cfg.FACTORIO_RCON_PORT) { $cfg.FACTORIO_RCON_PORT } else { "27015" }
if (-not $cfg.FACTORIO_RCON_PASSWORD) { throw "FACTORIO_RCON_PASSWORD missing in bridge\.env" }

$saves = Join-Path $client "saves"
if ($Save) {
    $savePath = Join-Path $saves ($Save -replace '\.zip$', '') | ForEach-Object { "$_.zip" }
} else {
    $savePath = (Get-ChildItem $saves -Filter *.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not (Test-Path $savePath)) { throw "Save not found: $savePath" }

New-Item -ItemType Directory -Force -Path $server | Out-Null
@"
[path]
read-data=__PATH__executable__\..\..\data
write-data=$server
"@ | Set-Content -Encoding ascii (Join-Path $server "config.ini")

@{
    name                          = "AI player test"
    description                   = "local only"
    visibility                    = @{ public = $false; lan = $false }
    require_user_verification     = $false
    game_password                 = ""
    max_players                   = 4
    autosave_interval             = 5
    autosave_slots                = 5
    autosave_only_on_server       = $true
    only_admins_can_pause_the_game = $true
    auto_pause                    = $true
} | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $server "server-settings.json")
Copy-Item (Join-Path $client "server-adminlist.json") (Join-Path $server "server-adminlist.json") -Force

Write-Host "Save   : $savePath"
Write-Host "Output : $server\script-output\ai-player   (bridge reads this)"
Write-Host "Join   : Multiplayer -> Connect to address -> 127.0.0.1"
Write-Host "Stop   : Ctrl+C here (the server saves first)"
& $exe --config (Join-Path $server "config.ini") `
       --mod-directory (Join-Path $client "mods") `
       --start-server $savePath `
       --server-settings (Join-Path $server "server-settings.json") `
       --server-adminlist (Join-Path $server "server-adminlist.json") `
       --bind 127.0.0.1 `
       --rcon-bind "127.0.0.1:$rconPort" `
       --rcon-password $cfg.FACTORIO_RCON_PASSWORD
