<#
.SYNOPSIS
    Unattended Ultra-Fast Self-Improvement & Benchmark Runner for Factorio AI Bridge.
.DESCRIPTION
    Runs continuous 2-to-3 minute micro-sprints at 8x-10x speed with local AI reflection,
    tracking Personal Best (PB) times and distilling heuristics into memory.
.PARAMETER Hours
    Total runtime in hours before terminating (default: 2.0).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\run_unattended.ps1 -Hours 3
#>

param(
    [double]$Hours = 2.0,
    [double]$Speed = 8.0,
    [switch]$NoLLM
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) {
    Write-Error "Python venv not found at $Python. Please run .venv setup first."
    exit 1
}

$RouterUrl = "http://127.0.0.1:11440/v1/models"
try {
    $res = Invoke-RestMethod -Uri $RouterUrl -TimeoutSec 3 -ErrorAction SilentlyContinue
    Write-Host "[Local AI] Router is UP on :11440 (Model: sol-fast ready)." -ForegroundColor Green
} catch {
    Write-Host "[Local AI] Warning: Router on :11440 not responding. Sprints will fallback to coach rules." -ForegroundColor Yellow
}

$TotalSeconds = $Hours * 3600
$StartTime = [DateTime]::UtcNow
$EndTime = $StartTime.AddSeconds($TotalSeconds)

$Sprints = @("red", "green", "steel")
$Seeds = @(424242, 2476103329, 1873625901, 3598211047)

$Iteration = 0
$CompletedCount = 0
$NewPBCount = 0

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  FACTORIO AI BRIDGE: UNATTENDED ULTRA-FAST SELF-IMPROVEMENT LOOP    " -ForegroundColor Cyan
Write-Host "  Runtime Budget: $Hours hours ($([math]::Round($TotalSeconds/60)) minutes) | Speed: ${Speed}x" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Press Ctrl+C at any time to pause and generate the report.`n" -ForegroundColor DarkGray

$LeaderboardPath = Join-Path $RepoRoot "memory\leaderboard.json"
$PlaybookPath = Join-Path $RepoRoot "memory\speedrun_playbook.json"
$ReportPath = Join-Path $RepoRoot "UNATTENDED_SPEEDRUN_REPORT.md"

try {
    while ([DateTime]::UtcNow -lt $EndTime) {
        $Iteration++
        $sprintKey = $Sprints[($Iteration - 1) % $Sprints.Count]
        $seed = $Seeds[($Iteration - 1) % $Seeds.Count]

        $elapsedSoFar = [DateTime]::UtcNow - $StartTime
        $remaining = $EndTime - [DateTime]::UtcNow
        $elapsedStr = "{0:D2}:{1:D2}:{2:D2}" -f $elapsedSoFar.Hours, $elapsedSoFar.Minutes, $elapsedSoFar.Seconds
        $remainStr = "{0:D2}:{1:D2}:{2:D2}" -f $remaining.Hours, $remaining.Minutes, $remaining.Seconds

        Write-Host "[$elapsedStr elapsed | $remainStr left] Run #$Iteration: Sprint '$sprintKey' (Seed $seed)" -ForegroundColor White

        $llmFlag = if ($NoLLM) { "--no-llm" } else { "" }
        $cmd = "& `"$Python`" `"$RepoRoot\scripts\fast_sprint_runner.py`" --sprint $sprintKey --seed $seed --speed $Speed $llmFlag --max-sec 200"
        Invoke-Expression $cmd

        Start-Sleep -Seconds 2
    }
} finally {
    Write-Host "`nGenerating consolidated summary report..." -ForegroundColor Cyan

    $report = @()
    $report += "# Factorio AI Bridge: Unattended Speedrun & Improvement Report"
    $report += ""
    $report += "Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') after $Iteration sprint iterations."
    $report += ""
    $report += "## Personal Best (PB) Leaderboard"
    $report += ""
    $report += "| Sprint | Best Time | Best Seed | Completed / Total Runs |"
    $report += "|---|---|---|---|"

    if (Test-Path $LeaderboardPath) {
        $lb = Get-Content $LeaderboardPath -Raw | ConvertFrom-Json
        foreach ($key in @("red", "green", "steel", "oil")) {
            if ($lb.PSObject.Properties[$key]) {
                $e = $lb.$key
                $bestTime = if ($e.best_time) { "$($e.best_time)s" } else { "N/A" }
                $bestSeed = if ($e.best_seed) { "$($e.best_seed)" } else { "-" }
                $runs = "$($e.runs_completed) / $($e.runs_total)"
                $report += "| **$key** | $bestTime | $bestSeed | $runs |"
            }
        }
    } else {
        $report += "| No runs recorded | - | - | - |"
    }

    $report += ""
    $report += "## Distilled Speedrun Playbook Heuristics"
    $report += ""
    if (Test-Path $PlaybookPath) {
        $pb = Get-Content $PlaybookPath -Raw | ConvertFrom-Json
        foreach ($rule in $pb.rules) {
            $report += "- $rule"
        }
    } else {
        $report += "_No heuristics generated yet._"
    }

    $report -join "`n" | Set-Content -Path $ReportPath -Encoding utf8
    Write-Host "Report saved to: $ReportPath" -ForegroundColor Green
    Write-Host "All done! Safe travels!" -ForegroundColor Green
}
