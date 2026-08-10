# Shared project -> color mapping.
# Dot-sourced by statusline.ps1 (in-window label) and New-CCProfiles.ps1
# (Windows Terminal tabColor) so both always agree on a project's color.
#
# Assignments live in cc-colors.json. New-CCProfiles.ps1 writes that file,
# picking colors that don't collide with projects already assigned; the hash
# below is only the starting guess and the fallback for unmapped projects.

$script:CCPalette = @(
    '#E05252', '#E07B39', '#D9A93C', '#A8C43A',
    '#5FBF62', '#3FBF8F', '#2FB8B8', '#35A7D9',
    '#4A85E0', '#6B6BE0', '#8E5FE0', '#B455D6',
    '#D64FB4', '#E04F86', '#8C9BA5', '#B08968'
)

$script:CCColorMapPath = Join-Path $env:USERPROFILE '.claude\cc-colors.json'
$script:CCConfigPath = Join-Path $env:USERPROFILE '.claude\cc-config.json'

function Get-CCRoot {
    # Where this machine keeps its project folders. install.ps1 detects it and
    # writes cc-config.json; the probe list is the fallback for a hand copy.
    if (Test-Path $script:CCConfigPath) {
        try {
            $cfg = Get-Content $script:CCConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.root -and (Test-Path $cfg.root)) { return $cfg.root }
        } catch {}
    }
    # Drive letters are not hardcoded: a projects folder lives on D: or G: as
    # often as on C:, and guessing only C: was the reason this used to land on a
    # web docroot that held none of the actual work.
    $names = 'Project', 'Projects', 'Dev', 'src', 'Code', 'repos', 'workspace'
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady -or $d.DriveType -ne 'Fixed') { continue }
        foreach ($n in $names) {
            $p = Join-Path $d.RootDirectory.FullName $n
            if (Test-Path $p) { return $p }
        }
    }
    foreach ($n in 'source\repos', 'Projects', 'Dev', 'git', 'repos') {
        $p = Join-Path $env:USERPROFILE $n
        if (Test-Path $p) { return $p }
    }
    # Web stacks keep the projects under a fixed docroot instead of a plain folder
    foreach ($p in @(
            'D:\laragon\www', 'C:\laragon\www',
            (Join-Path $env:USERPROFILE 'laragon\www'),
            'D:\www', 'C:\www', 'C:\xampp\htdocs', 'C:\wamp64\www')) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $null
}

function Get-CCWTSettingsPath {
    # Store, Preview, and unpackaged (scoop/choco/zip) installs all differ
    foreach ($p in @(
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'))) {
        if (Test-Path $p) { return $p }
    }
    $null
}

function Get-CCColorIndex {
    param([Parameter(Mandatory)][string]$Name)
    # MD5 of the lowercased name -> stable palette index
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name.ToLower()))
    [int]$b[0] % $script:CCPalette.Count
}

function Get-CCColorMap {
    if ([IO.File]::Exists($script:CCColorMapPath)) {
        try {
            # [IO.File] rather than Get-Content: statusline.ps1 calls this on
            # every render and the cmdlet overhead is measurable there.
            $o = [IO.File]::ReadAllText($script:CCColorMapPath) | ConvertFrom-Json
            $h = @{}
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
            return $h
        } catch {}
    }
    @{}
}

function Get-CCColor {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Map
    )
    if (-not $PSBoundParameters.ContainsKey('Map')) { $Map = Get-CCColorMap }
    $k = $Name.ToLower()
    if ($Map.ContainsKey($k)) { return $Map[$k] }
    $script:CCPalette[(Get-CCColorIndex $Name)]
}

function Set-CCColorMap {
    param([Parameter(Mandatory)][hashtable]$Map)
    ([pscustomobject]$Map | ConvertTo-Json -Depth 5) |
        Set-Content $script:CCColorMapPath -Encoding UTF8
}

function ConvertFrom-CCHex {
    param([Parameter(Mandatory)][string]$Hex)
    $x = $Hex.TrimStart('#')
    [pscustomobject]@{
        R = [Convert]::ToInt32($x.Substring(0, 2), 16)
        G = [Convert]::ToInt32($x.Substring(2, 2), 16)
        B = [Convert]::ToInt32($x.Substring(4, 2), 16)
    }
}
