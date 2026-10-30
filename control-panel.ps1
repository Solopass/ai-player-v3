# Small window to launch, watch and stop the AI player pieces:
# the headless server, the bridge and the game window.
#
#   powershell -ExecutionPolicy Bypass -File .\control-panel.ps1
#   (or double-click "AI Control Panel.cmd")

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$repo    = $PSScriptRoot
$python  = Join-Path $repo ".venv\Scripts\python.exe"
$saves   = Join-Path $env:APPDATA "Factorio\saves"
$outDir  = Join-Path $env:APPDATA "Factorio-server\script-output\ai-player"
$steamId = 427520

# --- process lookup -------------------------------------------------------

# The venv's python.exe is a launcher that starts the real interpreter as a
# child with the same command line, so one bridge is two processes. Count only
# the outermost one.
function Get-BridgeRoots($procs) {
    $bridge = @($procs | Where-Object { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'bridge\.main' })
    $ids = @($bridge | ForEach-Object ProcessId)
    @($bridge | Where-Object { $ids -notcontains $_.ParentProcessId })
}

function Get-Pieces {
    $procs = Get-CimInstance Win32_Process -Filter "Name='factorio.exe' OR Name='python.exe' OR Name='powershell.exe' OR Name='pwsh.exe'"
    $factorio = @($procs | Where-Object Name -eq 'factorio.exe')
    [pscustomobject]@{
        Server = @($factorio | Where-Object { $_.CommandLine -match '--start-server' })
        Game   = @($factorio | Where-Object { $_.CommandLine -notmatch '--start-server' })
        Bridge = @(Get-BridgeRoots $procs)
        All    = $procs
    }
}

function Test-Port([int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $port).Wait(200) -and $c.Connected }
    catch { return $false }
    finally { $c.Close() }
}

function Get-RconPort {
    $line = Get-Content (Join-Path $repo "bridge\.env") -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\s*FACTORIO_RCON_PORT\s*=\s*(\d+)' } | Select-Object -First 1
    if ($line -and $line -match '(\d+)\s*$') { [int]$Matches[1] } else { 27015 }
}
$rconPort = Get-RconPort

# The game window holds UDP 34197 while it hosts a multiplayer game.
function Test-GameHosting($game) {
    $ids = @($game | ForEach-Object ProcessId)
    $ids.Count -and @(Get-NetUDPEndpoint -LocalPort 34197 -ErrorAction SilentlyContinue |
                      Where-Object { $ids -contains $_.OwningProcess }).Count
}

# Close the PowerShell window that hosted a process we stopped.
function Stop-WithParent($proc, [string]$parentMatch) {
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
    # Children first: the venv launcher doesn't take the real interpreter down with it.
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.ProcessId)" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    if ($parent -and $parent.Name -match 'powershell|pwsh' -and $parent.CommandLine -match $parentMatch) {
        Stop-Process -Id $parent.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Opens a PowerShell window in the repo that stays open only if the command fails.
function Start-Window([string]$title, [string]$command) {
    $cmd = "`$Host.UI.RawUI.WindowTitle = '$title'; Set-Location '$repo'; $command; " +
           "if (`$LASTEXITCODE) { Read-Host '$title exited with an error - press Enter to close' }"
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

# --- window ---------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Factorio AI - control panel"
$form.Size = New-Object System.Drawing.Size(560, 360)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

function New-Label($text, $x, $y, $w = 120) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = "$x,$y"; $l.Size = "$w,24"; $l.TextAlign = 'MiddleLeft'
    $form.Controls.Add($l); $l
}
function New-Button($text, $x, $y, $w, $onClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = "$x,$y"; $b.Size = "$w,30"
    $b.Add_Click($onClick)
    $form.Controls.Add($b); $b
}

$rows = @{}
$y = 16
foreach ($name in 'Server', 'Bridge', 'Game') {
    New-Label $name 16 $y 70 | ForEach-Object { $_.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold) }
    $rows[$name] = New-Label "..." 90 $y 230
    $y += 40
}

# Server row
$null = New-Button "Start" 330 12 90 {
    if ((Get-Pieces).Server.Count) { return }
    if (Test-GameHosting (Get-Pieces).Game) {
        [System.Windows.Forms.MessageBox]::Show("The game window is hosting a game on port 34197. Leave it first.") | Out-Null
        return
    }
    $arg = if ($saveBox.SelectedItem) { " -Save '$($saveBox.SelectedItem -replace "'", "''")'" } else { "" }
    Start-Window "Factorio server" "& .\start-server.ps1$arg"
}
$null = New-Button "Stop" 430 12 90 {
    if (-not (Get-Pieces).Server.Count) { return }
    $status.Text = "Saving and stopping the server..."
    Start-Process $python -ArgumentList '-m', 'bridge.servercmd', '--stop' -WorkingDirectory $repo -WindowStyle Hidden
}

# Bridge row
$null = New-Button "Start" 330 52 90 {
    if ((Get-Pieces).Bridge.Count) { return }
    Start-Window "AI bridge" "& '$python' -m bridge.main"
}
$null = New-Button "Stop" 430 52 90 {
    foreach ($p in (Get-Pieces).Bridge) { Stop-WithParent $p 'bridge\.main' }
}

# Game row
$null = New-Button "Start" 330 92 90 {
    if ((Get-Pieces).Game.Count) { return }
    Start-Process "steam://rungameid/$steamId"
}
$null = New-Button "Close" 430 92 90 {
    foreach ($p in (Get-Pieces).Game) { (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).CloseMainWindow() | Out-Null }
}

# Save picker
New-Label "Save" 16 136 70 | Out-Null
$saveBox = New-Object System.Windows.Forms.ComboBox
$saveBox.DropDownStyle = 'DropDownList'
$saveBox.Location = "90,136"; $saveBox.Size = "430,24"
Get-ChildItem $saves -Filter *.zip -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { [void]$saveBox.Items.Add($_.BaseName) }
if ($saveBox.Items.Count) { $saveBox.SelectedIndex = 0 }
$form.Controls.Add($saveBox)

# Extras
$null = New-Button "Start all" 16 180 120 {
    $p = Get-Pieces
    if (-not $p.Server.Count) {
        $arg = if ($saveBox.SelectedItem) { " -Save '$($saveBox.SelectedItem -replace "'", "''")'" } else { "" }
        Start-Window "Factorio server" "& .\start-server.ps1$arg"
    }
    if (-not $p.Bridge.Count) { Start-Window "AI bridge" "& '$python' -m bridge.main" }
    if (-not $p.Game.Count)   { Start-Process "steam://rungameid/$steamId" }
}
$null = New-Button "Stop all" 146 180 120 {
    $p = Get-Pieces
    foreach ($b in $p.Bridge) { Stop-WithParent $b 'bridge\.main' }
    if ($p.Server.Count) {
        $status.Text = "Saving and stopping the server..."
        Start-Process $python -ArgumentList '-m', 'bridge.servercmd', '--stop' -WorkingDirectory $repo -WindowStyle Hidden
    }
}
$null = New-Button "Diagnostics" 276 180 120 {
    Start-Process powershell -ArgumentList '-NoExit', '-NoProfile', '-Command',
        "`$Host.UI.RawUI.WindowTitle = 'AI diagnostics'; Set-Location '$repo'; `$env:PYTHONIOENCODING='utf-8'; & '$python' -m bridge.diag"
}
$null = New-Button "Logs folder" 406 180 114 {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Start-Process explorer.exe $outDir
}

$status = New-Label "" 16 228 504
$status.Size = "504,80"
$status.TextAlign = 'TopLeft'

# --- refresh --------------------------------------------------------------

$green = [System.Drawing.Color]::ForestGreen
$red   = [System.Drawing.Color]::Firebrick
$amber = [System.Drawing.Color]::DarkOrange

function Set-Row($name, $text, $color) { $rows[$name].Text = $text; $rows[$name].ForeColor = $color }

function Update-Status {
    $p = Get-Pieces
    $rcon   = Test-Port $rconPort
    $router = Test-Port 11440

    if (-not $p.Server.Count) { Set-Row Server "stopped" $red }
    elseif ($rcon)            { Set-Row Server "running, RCON ready" $green }
    else                      { Set-Row Server "starting (RCON not up yet)" $amber }

    switch ($p.Bridge.Count) {
        0       { Set-Row Bridge "stopped" $red }
        1       { Set-Row Bridge "running" $green }
        default { Set-Row Bridge "$($_) running - stop extras!" $amber }
    }

    if ($p.Game.Count) { Set-Row Game "running" $green } else { Set-Row Game "closed" $red }

    $notes = @()
    if (-not $router) { $notes += "Model router (port 11440) is off - the bridge can't think. Check the game guard / sol-llm mode." }
    if (-not $p.Server.Count -and (Test-GameHosting $p.Game)) {
        $notes += "The game window is hosting - RCON doesn't work there. Leave it and use the server."
    }
    if ($p.Server.Count -and $p.Game.Count) { $notes += "Join with Multiplayer -> Connect to address -> 127.0.0.1" }
    if ($status.Text -notmatch 'Saving' -or -not $p.Server.Count) {
        $status.Text = ($notes -join "`n")
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })
$form.Add_Shown({ Update-Status; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop() })

[void]$form.ShowDialog()
