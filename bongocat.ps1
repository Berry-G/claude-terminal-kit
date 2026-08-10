# Bongo cat for the Claude Code statusLine.
#
# Dot-sourced by statusline.ps1. Get-BongoCat returns one fixed-width string of
# art; statusline.ps1 puts it at the head of the single status row.
#
# There is no "is Claude thinking" field on the statusLine stdin payload, so
# busy state is inferred from how often we are being called: the timer alone
# re-runs us every refreshInterval, and anything faster than that means
# event-driven updates are firing, i.e. the session is actively doing work.
#
# The threshold sits between the two cadences and has to be re-derived whenever
# refreshInterval changes. At refreshInterval 3 the idle gap is ~3000ms while
# Claude Code debounces event updates at 300ms. The busy gap is not 300ms
# though: the status line takes ~650ms to run and a run still in flight is
# cancelled, so only every second or third event actually completes a render,
# putting real busy gaps at roughly 700-1000ms. An earlier 900ms threshold --
# calibrated back when refreshInterval was 1 -- cut straight through that band
# and made the cat flicker between busy and idle mid-command.
$script:BongoBusyGapMs = 1800

$script:BongoWidth = 11

function Get-BongoState {
    # One counter file per session, so two windows animate independently.
    param([string]$SessionId, [double]$ApiMs)

    $id = if ($SessionId) { $SessionId -replace '[^A-Za-z0-9_-]', '' } else { 'default' }
    $path = "$env:TEMP\cc-bongo-$id.txt"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    # .NET calls rather than cmdlets: this runs on the status line's hot path,
    # where cmdlet overhead is a large share of the whole budget.
    $n = 0; $lastMs = 0L; $lastApi = -1.0
    if ([IO.File]::Exists($path)) {
        $f = @()
        try { $f = [IO.File]::ReadAllText($path).Trim() -split '\|' } catch {}
        if ($f.Count -ge 3) {
            [int]::TryParse($f[0], [ref]$n) | Out-Null
            [long]::TryParse($f[1], [ref]$lastMs) | Out-Null
            [double]::TryParse($f[2], [ref]$lastApi) | Out-Null
        }
    }

    $gap = $now - $lastMs
    $busy = ($lastMs -gt 0 -and $gap -lt $script:BongoBusyGapMs) -or ($lastApi -ge 0 -and $ApiMs -gt $lastApi)

    $n = ($n + 1) % 600
    try { [IO.File]::WriteAllText($path, "$n|$now|$ApiMs") } catch {}

    [pscustomobject]@{ N = $n; Busy = $busy }
}

function Get-SubagentActivity {
    # Reads the marker that subagent-statusline.ps1 drops each refresh tick.
    # The marker goes stale rather than being cleared, because that script stops
    # running the moment the agent panel empties -- there is no "all done" tick
    # to clear on.
    #
    # The window has to clear several refresh ticks. At 6s it was two ticks of a
    # 3s refreshInterval, so one delayed tick was enough to drop rage mode
    # mid-run and flip the cat back and forth. Erring long only means rage mode
    # lingers a few seconds after the last subagent exits.
    #
    # Two keys, matching the two the producer writes. The session key is exact
    # but relies on the subagent payload carrying the same session_id the status
    # line sees; a live check found no marker under it at all, so the working
    # directory provides an independent second key. Whichever marker is present
    # and fresh wins.
    param([string]$SessionId, [string]$Project)
    $staleAfterMs = 12000

    $paths = @()
    $id = if ($SessionId) { $SessionId -replace '[^A-Za-z0-9_-]', '' } else { 'default' }
    $paths += "$env:TEMP\cc-subagents-$id.txt"
    if ($Project) {
        $p = $Project -replace '[^A-Za-z0-9_-]', ''
        if ($p) { $paths += "$env:TEMP\cc-subagents-proj-$p.txt" }
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($path in $paths) {
        if (-not [IO.File]::Exists($path)) { continue }

        $f = @()
        try { $f = [IO.File]::ReadAllText($path).Trim() -split '\|' } catch {}
        if ($f.Count -lt 2) { continue }

        $active = 0; $ts = 0L
        [int]::TryParse($f[0], [ref]$active) | Out-Null
        [long]::TryParse($f[1], [ref]$ts) | Out-Null

        if (($now - $ts) -gt $staleAfterMs) { continue }
        if ($active -gt 0) { return $active }
    }
    0
}

function Get-BongoCat {
    # Returns one string, exactly $BongoWidth visible columns, ANSI-colored.
    param(
        [int]$N,
        [bool]$Busy,
        [bool]$Rage = $false,
        [string]$Tint = '',   # ANSI SGR for the cat
        [string]$Dim = ''     # unused; kept so callers need not change
    )
    $e = [char]27
    $off = "$e[0m"

    # One row. The ear row folded into the face as (^o.o^) earlier; now the
    # desk row is gone too, so paw state is carried by the paw glyph itself:
    #   d / b  = paw raised mid-swing     \_ / _/ = paw landed on the desk
    # The paws trade places every frame, which reads as the drumming motion.
    #
    # Exactly $BongoWidth columns, and deliberately pure ASCII. Block/note
    # glyphs (U+2581, U+2584, U+266A, U+2229) are East-Asian *ambiguous* width,
    # so a terminal with a CJK font draws them two columns wide and the row
    # stops lining up with the info that follows. Do not reintroduce them.
    if ($Rage) {
        # Subagents / background work in flight. Ears give way to # anger veins
        # and the eyes screw shut, so rage is legible at a glance even though
        # the arm motion is the same two-frame swap as normal drumming.
        if ($N % 2 -eq 0) { $art = '*_(#>.<#)b' + "'" }
        else { $art = "'" + 'd(#>.<#)_*' }
    } elseif ($Busy) {
        # Two frames, not more. Frames only advance when this script re-runs,
        # and while Claude works that is roughly once a second (300ms debounce,
        # minus the runs cancelled because a render was still in flight). A
        # longer cycle would therefore read as *slower* flailing, not faster.
        # So: two frames, maximum amplitude, so every redraw is a full paw swap.
        #   ' = motion streak off the raised paw    * = impact spark
        if ($N % 2 -eq 0) { $art = '*_(^o.o^)b' + "'" }   # left slams, right flies up
        else { $art = "'" + 'd(^o.o^)_*' }                # right slams, left flies up
    } else {
        # Idle: paws down, eyes open, blinking. This stands in for "the user is
        # typing" -- the real thing is not detectable. The statusLine stdin
        # payload carries no input-buffer field, and keystrokes are not one of
        # the events that re-run this script, so a status line simply cannot
        # see the prompt box. Idle is the closest honest proxy: when Claude is
        # not working, the human at the keyboard is.
        #
        # One tick is the shortest blink available, and refreshInterval had to be
        # raised to 3s to stop the status line being cancelled mid-render, so the
        # blink is now a slow doze rather than a blink. Closed on every 7th tick
        # keeps it occasional instead of looking asleep.
        if ($N % 7 -eq 0) { $art = '\_(^-.-^)_/' }
        else { $art = '\_(^o.o^)_/' }
    }

    "$Tint$art$off"
}
