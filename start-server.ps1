# Runs a Factorio save on a local headless server with RCON, for the bridge.
# The normal game window ignores --rcon-* even when hosting, so the bridge can
# only talk to a dedicated server. Join it from the game: Multiplayer ->
# Connect to address -> 127.0.0.1
#
#   .\start-server.ps1                     # newest save in %APPDATA%\Factorio\saves
#   .\start-server.ps1 -Save "SPACE REN"   # a save by name
param([string]$Save = "")

$ErrorActionPreference = "Stop"
$exe     = "E:\SteamLibrary\steamapps\common\Factorio\bin\x64\factorio.exe"
$client  = Join-Path $env:APPDATA "Factorio"
$server  = Join-Path $env:APPDATA "Factorio-server"   # own write-data: the game window locks its own
$envFile = Join-Path $PSScriptRoot "bridge\.env"

# RCON settings come from bridge/.env so the password lives in one place.
$cfg = @{}
foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
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
