<#
.SYNOPSIS
    Open a colored Windows Terminal tab running Claude Code in a project.

.DESCRIPTION
    For the projects that don't warrant a permanent profile (there are 52 folders
    under D:\laragon\www and the new-tab menu can only hold so many). Assigns the
    project a color on first use and records it in cc-colors.json, so the tab
    color matches the block statusline.ps1 draws inside the session.

.EXAMPLE
    cc sinsegaew        # exact name
    cc yeo              # prefix/substring is enough when unambiguous
    cc                  # list projects
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Project,
    # projects root; defaults to cc-config.json / auto-detection
    [string]$Root,
    # open in a new window instead of a tab in the current one
    [switch]$NewWindow
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'cc-palette.ps1')

if (-not $Root) { $Root = Get-CCRoot }
if (-not $Root) { throw 'No projects root found. Pass -Root, or set it in ~\.claude\cc-config.json' }

$dirs = (Get-ChildItem $Root -Directory).Name | Sort-Object

if (-not $Project) {
    Write-Host "Projects under ${Root}:" -ForegroundColor Cyan
    $dirs -join '  '
    return
}

# exact -> prefix -> substring
$match = @($dirs | Where-Object { $_ -eq $Project })
if (-not $match) { $match = @($dirs | Where-Object { $_ -like "$Project*" }) }
if (-not $match) { $match = @($dirs | Where-Object { $_ -like "*$Project*" }) }

if (-not $match) { throw "No project matching '$Project' under $Root" }
if ($match.Count -gt 1) { throw "'$Project' is ambiguous: $($match -join ', ')" }

$name = $match[0]
$dir = Join-Path $Root $name

# assign a color on first use, avoiding ones already handed out
$map = Get-CCColorMap
$k = $name.ToLower()
if (-not $map.ContainsKey($k)) {
    $taken = @{}
    foreach ($v in $map.Values) { $taken[$v] = 1 + ($taken[$v] ?? 0) }
    $start = Get-CCColorIndex $name
    $pick = $null
    for ($i = 0; $i -lt $CCPalette.Count; $i++) {
        $cand = $CCPalette[($start + $i) % $CCPalette.Count]
        if (-not $taken.ContainsKey($cand)) { $pick = $cand; break }
    }
    if (-not $pick) { $pick = ($taken.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key }
    $map[$k] = $pick
    Set-CCColorMap $map
}
$hex = $map[$k]

# -w 0 targets the current window; no --title, so Claude's hook still owns it
$target = if ($NewWindow) { '-w', 'new' } else { '-w', '0' }
& wt.exe @target new-tab --tabColor $hex --startingDirectory $dir pwsh.exe -NoExit -Command claude
Write-Host "$name  $hex" -ForegroundColor Green
