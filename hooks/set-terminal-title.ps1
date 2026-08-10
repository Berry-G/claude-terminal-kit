# Claude Code hook: prepend the project folder name to the terminal title.
# Claude Code auto-sets the title to the session topic (with an animated
# spinner glyph while busy), so a one-shot rewrite gets clobbered.
#
# Design: the hook (SessionStart/Stop) records the project name for this
# console and spawns ONE persistent watcher per console (mutex-guarded).
# The watcher only rewrites the title when it is IDLE-STABLE: the same
# value on two consecutive 2s samples. While Claude is busy the spinner
# changes the title constantly, so samples never match and the watcher
# stays hands-off.
param([switch]$Watch)

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -Namespace Win32 -Name Kernel -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
$hwnd = [Win32.Kernel]::GetConsoleWindow()
$projFile = Join-Path $env:TEMP "claude-title-proj-$hwnd.txt"

if (-not $Watch) {
    # --- hook mode: record project name, ensure watcher is running ---
    try { $stdin = [Console]::In.ReadToEnd() } catch { $stdin = $null }
    $cwd = $null
    if ($stdin) {
        try { $cwd = ($stdin | ConvertFrom-Json).cwd } catch {}
    }
    if (-not $cwd) { $cwd = (Get-Location).Path }
    $proj = Split-Path -Leaf $cwd
    Set-Content -Path $projFile -Value $proj

    # spawn watcher attached to this console; the mutex below makes
    # duplicate spawns (every Stop hook) exit immediately
    Start-Process pwsh -NoNewWindow -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-Watch')
    exit
}

# --- watch mode: one instance per console ---
$mutex = New-Object System.Threading.Mutex($false, "Local\claude-title-watch-$hwnd")
if (-not $mutex.WaitOne(0)) { exit }

$prev = $null
while ($true) {
    # re-read each pass so a claude session started later in another
    # project dir retargets this console's prefix without a respawn
    $proj = Get-Content $projFile | Select-Object -First 1
    if ($proj) {
        $clean = ([Console]::Title) -replace '^(Administrator|관리자):\s*', ''
        if ($clean -and $clean -eq $prev -and -not $clean.StartsWith("$proj-")) {
            # idle-stable and unprefixed: strip decoration glyphs, prefix
            $stripped = $clean -replace '^[^\p{L}\p{N}]+', ''
            if ($stripped) { [Console]::Title = "$proj-$stripped" }
        }
        $prev = $clean
    }
    Start-Sleep -Seconds 2
}
