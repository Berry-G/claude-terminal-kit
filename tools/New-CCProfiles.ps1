<#
.SYNOPSIS
    Generate one Windows Terminal profile per project, each with its own tab color.

.DESCRIPTION
    Tab color identifies the project; the tab TITLE is left alone so the
    Claude Code hook can keep using it for busy/idle state. Colors come from
    cc-palette.ps1, the same mapping statusline.ps1 uses, so the colored block
    inside the session matches the tab color of the window it lives in.

    Profile GUIDs are derived from the project name, so re-running updates the
    existing profiles instead of piling up duplicates.

.EXAMPLE
    .\New-CCProfiles.ps1 -Recent 12
    Profiles for the 12 most recently used Claude Code projects.

.EXAMPLE
    .\New-CCProfiles.ps1 -Projects sinsegaew, narrative, windjn

.EXAMPLE
    .\New-CCProfiles.ps1 -Recent 12 -WhatIf
    Show what would change without writing.

.EXAMPLE
    .\New-CCProfiles.ps1 -Clean
    Remove every generated profile.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Recent')]
param(
    # Project folder names under -Root (e.g. sinsegaew)
    [Parameter(ParameterSetName = 'Projects', Position = 0)]
    [string[]]$Projects,

    # Take the N most recently used projects from Claude Code's own history
    [Parameter(ParameterSetName = 'Recent')]
    [int]$Recent = 12,

    # Every folder under -Root (52 profiles today -- the new-tab menu gets long)
    [Parameter(ParameterSetName = 'All')]
    [switch]$All,

    # Delete all previously generated profiles and exit
    [Parameter(ParameterSetName = 'Clean')]
    [switch]$Clean,

    # projects root; defaults to cc-config.json / auto-detection
    [string]$Root,

    # Prefix on the profile name; also how generated profiles are recognized
    [string]$Prefix = 'CC',

    # Tint the window background with the project color (subtle, ~8%)
    [bool]$TintBackground = $true
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'cc-palette.ps1')

if (-not $Root) { $Root = Get-CCRoot }
if (-not $Root) { throw 'No projects root found. Pass -Root, or set it in ~\.claude\cc-config.json' }

$settingsPath = Get-CCWTSettingsPath
if (-not $settingsPath) { throw 'Windows Terminal settings.json not found -- is Windows Terminal installed?' }

function New-DeterministicGuid([string]$Text) {
    # Stable per name so re-runs update rather than duplicate.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    "{$([guid]::new($b).ToString())}"
}

function Get-Tint($c, [double]$Alpha) {
    # blend toward the terminal's near-black background
    $r = [int]($c.R * $Alpha); $g = [int]($c.G * $Alpha); $b = [int]($c.B * $Alpha)
    '#{0:X2}{1:X2}{2:X2}' -f $r, $g, $b
}

# ---- resolve the project list -------------------------------------------------
$names = @()
switch ($PSCmdlet.ParameterSetName) {
    'Projects' { $names = $Projects }
    'All' { $names = (Get-ChildItem $Root -Directory).Name }
    'Recent' {
        $histRoot = Join-Path $env:USERPROFILE '.claude\projects'
        # Claude Code encodes a path as D--laragon-www-<proj>, replacing every
        # separator with '-'. Project names may contain '-' too, so match against
        # the real folders and prefer the longest suffix that fits.
        $onDisk = (Get-ChildItem $Root -Directory).Name | Sort-Object Length -Descending
        $names = Get-ChildItem $histRoot -Directory |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $enc = $_.Name
                $onDisk | Where-Object { $enc -eq $_ -or $enc.EndsWith("-$_") } | Select-Object -First 1
            } |
            Select-Object -Unique -First $Recent
    }
}

# ---- load, back up ------------------------------------------------------------
$json = Get-Content $settingsPath -Raw -Encoding UTF8
$settings = $json | ConvertFrom-Json
$backup = "$settingsPath.bak"
$list = [System.Collections.ArrayList]@($settings.profiles.list)

# drop previously generated profiles (identified by the name prefix)
$marker = "$Prefix "
$removed = @($list | Where-Object { $_.name -like "$marker*" })
foreach ($r in $removed) { $list.Remove($r) }

if ($Clean) {
    $settings.profiles.list = $list.ToArray()
    if ($PSCmdlet.ShouldProcess($settingsPath, "remove $($removed.Count) generated profile(s)")) {
        Copy-Item $settingsPath $backup -Force
        ($settings | ConvertTo-Json -Depth 100) | Set-Content $settingsPath -Encoding UTF8
    }
    Write-Host "Removed $($removed.Count) '$Prefix ' profile(s). Backup: $backup"
    return
}

if (-not $names) { throw 'No projects resolved. Pass -Projects, or check -Root.' }

# ---- assign colors ------------------------------------------------------------
# Existing assignments win, so a project's color never moves under it. New ones
# start at their hash index and walk the palette to the first unused color;
# past 16 projects, reuse the least-used one.
$map = Get-CCColorMap
foreach ($n in $names) {
    $k = $n.ToLower()
    if ($map.ContainsKey($k)) { continue }
    $taken = @{}
    foreach ($v in $map.Values) { $taken[$v] = 1 + ($taken[$v] ?? 0) }
    $start = Get-CCColorIndex $n
    $pick = $null
    for ($i = 0; $i -lt $CCPalette.Count; $i++) {
        $cand = $CCPalette[($start + $i) % $CCPalette.Count]
        if (-not $taken.ContainsKey($cand)) { $pick = $cand; break }
    }
    if (-not $pick) {
        $pick = ($taken.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
    }
    $map[$k] = $pick
}

# ---- build --------------------------------------------------------------------
$added = @()
foreach ($n in $names) {
    $dir = Join-Path $Root $n
    if (-not (Test-Path $dir)) { Write-Warning "skip '$n': $dir not found"; continue }

    $hex = Get-CCColor -Name $n -Map $map
    $c = ConvertFrom-CCHex $hex
    $p = [ordered]@{
        guid             = New-DeterministicGuid "claude-code-profile:$n"
        name             = "$Prefix $n"
        commandline      = 'pwsh.exe -NoExit -Command claude'
        startingDirectory = $dir
        tabColor         = $hex
        # never set tabTitle / suppressApplicationTitle here: both would freeze
        # the title and kill the busy/idle signal the Claude hook writes to it
        suppressApplicationTitle = $false
        hidden           = $false
    }
    if ($TintBackground) { $p.background = Get-Tint $c 0.10 }

    [void]$list.Add([pscustomobject]$p)
    $added += [pscustomobject]@{ Project = $n; Color = $hex; Path = $dir }
}

$settings.profiles.list = $list.ToArray()

if ($PSCmdlet.ShouldProcess($settingsPath, "write $($added.Count) profile(s)")) {
    Copy-Item $settingsPath $backup -Force
    ($settings | ConvertTo-Json -Depth 100) | Set-Content $settingsPath -Encoding UTF8
    Set-CCColorMap $map   # statusline.ps1 reads this, so tab and label match
    Write-Host "Wrote $($added.Count) profile(s). Backup: $backup" -ForegroundColor Green
} else {
    Write-Host 'Dry run -- nothing written.' -ForegroundColor Yellow
}
$added | Format-Table -AutoSize
