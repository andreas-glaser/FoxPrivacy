<#
.SYNOPSIS
  FoxPrivacy - turn off Firefox telemetry, sponsored content, and nagging
  without breaking Firefox.

.DESCRIPTION
  Builds a Firefox enterprise policies.json from the feature manifest and
  installs it where Firefox reads it, backing up whatever was there first.

  Uses only what ships with Windows. PowerShell 5.1 or newer, nothing to
  install first. Run with no arguments for the interactive menu.

.EXAMPLE
  .\foxprivacy.ps1
  Interactive menu.

.EXAMPLE
  .\foxprivacy.ps1 -Profile standard
  Install the safe defaults.

.EXAMPLE
  .\foxprivacy.ps1 -Uninstall
  Restore whatever was there before FoxPrivacy.
#>

[CmdletBinding()]
param(
    [Alias('Profile')]
    [string]$ProfileName = '',

    [string]$Enable = '',
    [string]$Disable = '',
    [string]$Target = '',

    [Alias('i')]
    [switch]$Interactive,

    [Alias('l')]
    [switch]$List,

    [switch]$Verify,

    [Alias('u')]
    [switch]$Uninstall,

    [Alias('n')]
    [switch]$DryRun,

    [switch]$Force,

    [Alias('v')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FoxPrivacyVersion = '1.0.0'

# --------------------------------------------------------------- output ----

function Write-Info { param([string]$Message) Write-Host $Message }
function Write-Ok   { param([string]$Message) Write-Host "OK " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn { param([string]$Message) Write-Host "warning: " -ForegroundColor Yellow -NoNewline; Write-Host $Message }

function Stop-WithError {
    param([string]$Message)
    Write-Host "error: " -ForegroundColor Red -NoNewline
    Write-Host $Message
    exit 1
}

# ------------------------------------------------------------- manifest ----

function Get-ScriptPath {
    if ($PSCommandPath) { return $PSCommandPath }
    return $MyInvocation.MyCommand.Path
}

# The manifest lives beside the script in a checkout, or is appended to this
# file after the marker below in the single file release build, as comment
# lines so the distributed file stays valid PowerShell all the way down.
function Get-Manifest {
    if ($env:FOXPRIVACY_MANIFEST) {
        if (-not (Test-Path -LiteralPath $env:FOXPRIVACY_MANIFEST)) {
            Stop-WithError "manifest not found: $($env:FOXPRIVACY_MANIFEST)"
        }
        return Get-Content -LiteralPath $env:FOXPRIVACY_MANIFEST
    }

    $scriptPath = Get-ScriptPath
    $scriptDir = Split-Path -Parent $scriptPath

    # A release build carries its own manifest and must use it. Checking the
    # filesystem first would let an unrelated checkout nearby silently override
    # what the downloaded file says it does.
    if (Test-Path -LiteralPath $scriptPath) {
        $lines = Get-Content -LiteralPath $scriptPath
        $marker = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq '#__MANIFEST__') { $marker = $i; break }
        }
        if ($marker -ge 0) {
            $embedded = @()
            for ($i = $marker + 1; $i -lt $lines.Count; $i++) {
                $embedded += ($lines[$i] -replace '^# ?', '')
            }
            return $embedded
        }
    }

    $candidates = @(
        (Join-Path (Split-Path -Parent $scriptDir) 'policies\features.conf'),
        (Join-Path $scriptDir 'features.conf')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return Get-Content -LiteralPath $c }
    }

    Stop-WithError @"
no feature manifest found.
  Looked for policies\features.conf beside the script and for an embedded copy.
"@
}

# Parses the manifest into an ordered list of features. Mirrors the awk parser
# in foxprivacy.sh exactly; the two must produce identical policy files.
function Read-Features {
    param([string[]]$Lines)

    $features = New-Object System.Collections.ArrayList
    $current = $null

    foreach ($line in $Lines) {
        if ($line -match '^[ \t]*#') { continue }
        $ci = $line.IndexOf(':')
        if ($ci -lt 0) { continue }
        $key = $line.Substring(0, $ci)
        $value = $line.Substring($ci + 1).Trim()

        switch ($key) {
            'feature' {
                $current = [ordered]@{
                    id = $value; name = ''; summary = ''; cost = ''
                    presets = @(); policies = New-Object System.Collections.ArrayList
                    prefs = New-Object System.Collections.ArrayList
                }
                [void]$features.Add($current)
            }
            'name'    { if ($current) { $current.name = $value } }
            'summary' { if ($current) { $current.summary = $value } }
            'cost'    { if ($current) { $current.cost = $value } }
            'presets' {
                if ($current) {
                    $current.presets = @($value -split '\s+' | Where-Object { $_ -ne '' })
                }
            }
            'policy' {
                if ($current) {
                    $ei = $value.IndexOf(' = ')
                    if ($ei -lt 0) { Stop-WithError "manifest error: policy line is not <key> = <value>: $value" }
                    [void]$current.policies.Add(@{
                        Path = $value.Substring(0, $ei)
                        Value = $value.Substring($ei + 3)
                    })
                }
            }
            'pref' {
                if ($current) {
                    $ei = $value.IndexOf(' = ')
                    if ($ei -lt 0) { Stop-WithError "manifest error: pref line is not <name> = <value> [status]: $value" }
                    $name = $value.Substring(0, $ei)
                    $rest = $value.Substring($ei + 3)
                    $sp = $rest.IndexOf(' ')
                    if ($sp -lt 0) { $pv = $rest; $ps = 'default' }
                    else { $pv = $rest.Substring(0, $sp); $ps = $rest.Substring($sp + 1) }
                    if ($ps -notin @('default', 'locked', 'user', 'clear')) {
                        Stop-WithError "manifest error: preference status must be default, locked, user, or clear: $ps"
                    }
                    [void]$current.prefs.Add(@{ Name = $name; Value = $pv; Status = $ps })
                }
            }
        }
    }
    return $features
}

# ----------------------------------------------------------- json writer ----

# Hand written rather than ConvertTo-Json so the output is byte identical to
# what the shell installer produces on Linux and macOS. CI compares the two.
function ConvertTo-JsonValue {
    param([string]$Raw)
    if ($Raw -match '["\\]') { Stop-WithError "manifest error: value contains a quote or backslash: $Raw" }
    if ($Raw -eq 'true' -or $Raw -eq 'false') { return $Raw }
    if ($Raw -match '^-?[0-9]+$') { return $Raw }
    return '"' + $Raw + '"'
}

function Build-PolicyJson {
    param($Features, [string[]]$Selected)

    $topOrder = New-Object System.Collections.ArrayList
    $leafValue = @{}
    $childOrder = @{}
    $childValue = @{}
    $isLeaf = @{}
    $hasChild = @{}

    $prefOrder = New-Object System.Collections.ArrayList
    $prefValue = @{}
    $prefStatus = @{}

    foreach ($f in $Features) {
        if ($Selected -notcontains $f.id) { continue }

        foreach ($p in $f.policies) {
            $path = $p.Path
            $di = $path.IndexOf('.')
            if ($di -lt 0) { $top = $path; $child = '' }
            else {
                $top = $path.Substring(0, $di)
                $child = $path.Substring($di + 1)
                if ($child.Contains('.')) {
                    Stop-WithError "manifest error: policy keys nest at most two deep: $path"
                }
            }
            if ($top -eq 'Preferences') {
                Stop-WithError "manifest error: use pref: lines, not a Preferences policy"
            }
            if (-not $topOrder.Contains($top)) { [void]$topOrder.Add($top) }
            if ($child -eq '') {
                if ($hasChild.ContainsKey($top)) {
                    Stop-WithError "manifest error: policy $top is used both as a value and as a group"
                }
                $isLeaf[$top] = $true
                $leafValue[$top] = $p.Value
            } else {
                if ($isLeaf.ContainsKey($top)) {
                    Stop-WithError "manifest error: policy $top is used both as a value and as a group"
                }
                $hasChild[$top] = $true
                if (-not $childOrder.ContainsKey($top)) {
                    $childOrder[$top] = New-Object System.Collections.ArrayList
                }
                if (-not $childOrder[$top].Contains($child)) { [void]$childOrder[$top].Add($child) }
                $childValue["$top|$child"] = $p.Value
            }
        }

        foreach ($pref in $f.prefs) {
            if (-not $prefOrder.Contains($pref.Name)) { [void]$prefOrder.Add($pref.Name) }
            $prefValue[$pref.Name] = $pref.Value
            $prefStatus[$pref.Name] = $pref.Status
        }
    }

    $fragments = New-Object System.Collections.ArrayList
    foreach ($top in $topOrder) {
        if ($isLeaf.ContainsKey($top)) {
            [void]$fragments.Add('    "' + $top + '": ' + (ConvertTo-JsonValue $leafValue[$top]))
        } else {
            $sb = '    "' + $top + '": {' + "`n"
            $children = $childOrder[$top]
            for ($j = 0; $j -lt $children.Count; $j++) {
                $c = $children[$j]
                $sb += '      "' + $c + '": ' + (ConvertTo-JsonValue $childValue["$top|$c"])
                if ($j -lt $children.Count - 1) { $sb += ",`n" } else { $sb += "`n" }
            }
            $sb += '    }'
            [void]$fragments.Add($sb)
        }
    }

    if ($prefOrder.Count -gt 0) {
        $sb = '    "Preferences": {' + "`n"
        for ($i = 0; $i -lt $prefOrder.Count; $i++) {
            $p = $prefOrder[$i]
            $sb += '      "' + $p + '": {' + "`n"
            $sb += '        "Value": ' + (ConvertTo-JsonValue $prefValue[$p]) + ",`n"
            $sb += '        "Status": "' + $prefStatus[$p] + '"' + "`n"
            $sb += '      }'
            if ($i -lt $prefOrder.Count - 1) { $sb += ",`n" } else { $sb += "`n" }
        }
        $sb += '    }'
        [void]$fragments.Add($sb)
    }

    $out = "{`n" + '  "policies": {' + "`n"
    for ($i = 0; $i -lt $fragments.Count; $i++) {
        $out += $fragments[$i]
        if ($i -lt $fragments.Count - 1) { $out += ",`n" } else { $out += "`n" }
    }
    $out += '  }' + "`n" + '}' + "`n"
    return $out
}

# ---------------------------------------------------------- environment ----

function Get-Root { if ($env:FOXPRIVACY_ROOT) { return $env:FOXPRIVACY_ROOT } return '' }

function Get-DefaultTarget {
    $root = Get-Root
    if ($root) {
        return (Join-Path $root 'Program Files\Mozilla Firefox\distribution\policies.json')
    }
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Mozilla Firefox') }
    $x86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($x86) { $candidates += (Join-Path $x86 'Mozilla Firefox') }

    # Prefer wherever firefox.exe actually is; a 32 bit Firefox on a 64 bit
    # Windows lives in the x86 tree and writing to the other one does nothing.
    foreach ($dir in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $dir 'firefox.exe')) {
            return (Join-Path $dir 'distribution\policies.json')
        }
    }
    if ($candidates.Count -gt 0) {
        return (Join-Path $candidates[0] 'distribution\policies.json')
    }
    Stop-WithError 'could not determine the Firefox installation directory'
}

function Get-StateDir {
    if ($env:FOXPRIVACY_STATE_DIR) { return $env:FOXPRIVACY_STATE_DIR }
    $root = Get-Root
    if ($root) { return (Join-Path $root 'ProgramData\FoxPrivacy') }
    return (Join-Path $env:ProgramData 'FoxPrivacy')
}

function Get-StateFile { return (Join-Path (Get-StateDir) 'state') }

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

# A UTF-8 BOM in policies.json makes Firefox reject the whole file, so the
# encoding is stated explicitly rather than left to whatever the host defaults to.
function Write-TextFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ------------------------------------------------------------------ state ----

function Read-State {
    $file = Get-StateFile
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $state = @{}
    foreach ($line in (Get-Content -LiteralPath $file)) {
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) { continue }
        $state[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
    }
    return $state
}

function Get-StateValue {
    param($State, [string]$Key)
    if ($null -eq $State) { return '' }
    if (-not $State.ContainsKey($Key)) { return '' }
    return $State[$Key]
}

function Assert-StateUsable {
    param([string]$TargetPath, [string]$Sha)
    if ($TargetPath -and $Sha) { return }
    Stop-WithError @"
the record at $(Get-StateFile) is incomplete or unreadable.
  FoxPrivacy will not act on a record it cannot understand, because it cannot
  tell which file is ours. Inspect that file and remove both by hand if the
  policy file is yours to remove.
"@
}

function Write-State {
    param([string]$Prof, [string]$TargetPath, [string]$Backup, [string]$Sha, [string[]]$Selected)
    $dir = Get-StateDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $lines = @(
        "version=$FoxPrivacyVersion",
        "installed_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "profile=$Prof",
        "target=$TargetPath",
        "backup=$Backup",
        "sha256=$Sha",
        "features=$($Selected -join ' ')"
    )
    Write-TextFile -Path (Get-StateFile) -Content (($lines -join "`n") + "`n")
}

# --------------------------------------------------------------- selection ----

function Get-PresetIds {
    param($Features, [string]$Preset)
    return @($Features | Where-Object { $_.presets -contains $Preset } | ForEach-Object { $_.id })
}

function Get-PresetNames {
    param($Features)
    $names = New-Object System.Collections.ArrayList
    foreach ($f in $Features) {
        foreach ($p in $f.presets) { if (-not $names.Contains($p)) { [void]$names.Add($p) } }
    }
    return $names
}

# Keeps a selection in manifest order so generated files are stable.
function Sort-Selection {
    param($Features, [string[]]$Selected)
    return @($Features | Where-Object { $Selected -contains $_.id } | ForEach-Object { $_.id })
}

# ------------------------------------------------------------------ verbs ----

function Invoke-List {
    param($Features)
    Write-Host "FoxPrivacy features" -ForegroundColor White
    Write-Host ''
    foreach ($f in $Features) {
        Write-Host ("  {0,-26} {1}" -f $f.id, $f.name)
        Write-Host ("  {0,-26} {1}" -f '', $f.summary) -ForegroundColor DarkGray
        Write-Host ("  {0,-26} in: {1}" -f '', ($f.presets -join ', ')) -ForegroundColor DarkGray
        if ($f.cost) { Write-Host ("  {0,-26} cost: {1}" -f '', $f.cost) -ForegroundColor Yellow }
        Write-Host ''
    }
}

function Invoke-Verify {
    param([string]$TargetPath)
    $state = Read-State

    if ($null -eq $state) {
        if (Test-Path -LiteralPath $TargetPath) {
            Write-Host 'not installed by FoxPrivacy' -ForegroundColor Yellow
            Write-Info "A policies.json exists at $TargetPath but FoxPrivacy did not put it there."
            return 2
        }
        Write-Host 'not installed' -ForegroundColor Yellow
        Write-Info "No policy file at $TargetPath"
        return 1
    }

    $recordedTarget = Get-StateValue $state 'target'
    $recordedSha = Get-StateValue $state 'sha256'
    Assert-StateUsable $recordedTarget $recordedSha

    if (-not (Test-Path -LiteralPath $recordedTarget)) {
        Write-Host 'missing' -ForegroundColor Red
        Write-Info "FoxPrivacy installed $recordedTarget but it is gone."
        Write-Info 'A Firefox update may have removed it. Re-run the installer.'
        return 2
    }
    if ((Get-Sha256 $recordedTarget) -ne $recordedSha) {
        Write-Host 'changed' -ForegroundColor Yellow
        Write-Info "$recordedTarget has been modified since FoxPrivacy installed it."
        Write-Info 'Re-run the installer to restore it, or leave it if the change was yours.'
        return 2
    }

    Write-Ok 'installed and unchanged'
    Write-Info ("  profile:  " + (Get-StateValue $state 'profile'))
    Write-Info ("  target:   " + $recordedTarget)
    Write-Info ("  features: " + (@((Get-StateValue $state 'features') -split '\s+' | Where-Object { $_ })).Count + ' enabled')
    Write-Info ("  since:    " + (Get-StateValue $state 'installed_at'))
    Write-Host ''
    Write-Host 'Restart Firefox and open about:policies to confirm it took effect.' -ForegroundColor DarkGray
    return 0
}

function Invoke-Install {
    param($Features, [string]$Prof, [string[]]$Selected, [string]$TargetPath)

    if ($Selected.Count -eq 0) { Stop-WithError 'nothing selected. Nothing would change.' }

    $body = Build-PolicyJson -Features $Features -Selected $Selected
    $dir = Split-Path -Parent $TargetPath

    if ($DryRun) {
        Write-Host 'Dry run. Nothing was written.' -ForegroundColor White
        Write-Host ''
        Write-Info "would write:   $TargetPath"
        if (Test-Path -LiteralPath $TargetPath) {
            Write-Info "would back up: $TargetPath -> $TargetPath.foxprivacy-backup-<timestamp>"
        } else {
            Write-Info 'would back up: nothing, no file there yet'
        }
        Write-Info "profile:       $Prof"
        Write-Info "features:      $($Selected.Count) enabled"
        Write-Host ''
        Write-Host $body
        return
    }

    $state = Read-State
    $priorTarget = Get-StateValue $state 'target'
    if ($priorTarget -and $priorTarget -ne $TargetPath -and (Test-Path -LiteralPath $priorTarget) -and -not $Force) {
        Stop-WithError @"
FoxPrivacy is already installed at $priorTarget.
  Installing to $TargetPath as well would lose the record of the first one, and
  uninstall could never clean it up. Uninstall that one first, or re-run with
  -Force to abandon the record of it.
"@
    }

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop)
        }
    } catch {
        Stop-WithError @"
cannot create $dir
  This almost always means PowerShell is not running as Administrator.
  Close this window, right click Windows PowerShell, choose Run as
  administrator, and run the command again.
"@
    }

    # Back up anything we did not write ourselves. A file we installed is
    # replaced, and the original backup reference carries forward so uninstall
    # still restores what the user actually had.
    $backup = Get-StateValue $state 'backup'
    $oursSha = Get-StateValue $state 'sha256'
    if (Test-Path -LiteralPath $TargetPath) {
        if ((Get-Sha256 $TargetPath) -ne $oursSha) {
            $stamp = [DateTime]::Now.ToString('yyyyMMddTHHmmss')
            $backup = "$TargetPath.foxprivacy-backup-$stamp"
            Copy-Item -LiteralPath $TargetPath -Destination $backup
            Write-Info "backed up existing policies.json to $backup"
        }
    }

    $tmp = "$TargetPath.foxprivacy-tmp"
    try {
        Write-TextFile -Path $tmp -Content $body
        Move-Item -LiteralPath $tmp -Destination $TargetPath -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Stop-WithError @"
cannot write $TargetPath
  This almost always means PowerShell is not running as Administrator.
  Close this window, right click Windows PowerShell, choose Run as
  administrator, and run the command again.
"@
    }

    try {
        Write-State -Prof $Prof -TargetPath $TargetPath -Backup $backup `
            -Sha (Get-Sha256 $TargetPath) -Selected $Selected
    } catch {
        # A policy file we cannot prove we wrote is one uninstall will refuse to
        # remove, so undo rather than leave it.
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $TargetPath -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $TargetPath) {
            Remove-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
        }
        Stop-WithError @"
could not record the install in $(Get-StateDir), so it was undone.
  Nothing has been changed. This usually means PowerShell is not running as
  Administrator.
"@
    }

    Write-Ok "installed the $Prof profile to $TargetPath"
    Write-Info "$($Selected.Count) features enabled"
    Write-Host ''
    Write-Host 'Next: quit Firefox completely, start it again, and open about:policies.' -ForegroundColor White
    Write-Host 'The Errors tab must be empty. That is the only proof Firefox accepted this.' -ForegroundColor DarkGray
}

function Invoke-Uninstall {
    param([string]$TargetPath)
    $state = Read-State

    if ($null -eq $state) {
        if (Test-Path -LiteralPath $TargetPath) {
            Stop-WithError @"
there is a policies.json at $TargetPath but FoxPrivacy has no record of
  installing it. Refusing to touch a file that is not ours. Remove it by hand
  if you want it gone.
"@
        }
        Write-Info 'nothing to uninstall'
        return
    }

    $recordedTarget = Get-StateValue $state 'target'
    $backup = Get-StateValue $state 'backup'
    $recordedSha = Get-StateValue $state 'sha256'
    Assert-StateUsable $recordedTarget $recordedSha

    if ((Test-Path -LiteralPath $recordedTarget) -and (Get-Sha256 $recordedTarget) -ne $recordedSha -and -not $Force) {
        Stop-WithError @"
$recordedTarget has changed since FoxPrivacy installed it.
  Someone edited it, or another tool overwrote it. Refusing to remove it.
  Re-run with -Force if you are sure.
"@
    }

    if ($DryRun) {
        Write-Host 'Dry run. Nothing was removed.' -ForegroundColor White
        Write-Host ''
        if ($backup) { Write-Info "would restore: $backup -> $recordedTarget" }
        else { Write-Info "would remove:  $recordedTarget" }
        Write-Info "would remove:  $(Get-StateFile)"
        return
    }

    try {
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $recordedTarget -Force -ErrorAction Stop
            Write-Ok 'restored the policies.json that was there before FoxPrivacy'
        } else {
            if (Test-Path -LiteralPath $recordedTarget) {
                Remove-Item -LiteralPath $recordedTarget -Force -ErrorAction Stop
            }
            Write-Ok "removed $recordedTarget"
            if ($backup) { Write-Warn "the recorded backup $backup is gone, so nothing was restored" }
        }
    } catch {
        Stop-WithError @"
cannot change $recordedTarget
  This almost always means PowerShell is not running as Administrator.
"@
    }

    Remove-Item -LiteralPath (Get-StateFile) -Force
    $dir = Get-StateDir
    if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir)) {
        Remove-Item -LiteralPath $dir -Force
    }
    Write-Host ''
    Write-Host 'Restart Firefox. about:policies should now be empty.' -ForegroundColor DarkGray
}

# ------------------------------------------------------------ interactive ----

function Invoke-Interactive {
    param($Features, [string]$TargetPath)

    # Without a keyboard the menu would block on Read-Host until something
    # killed it. Say so instead.
    if ([Console]::IsInputRedirected) {
        Stop-WithError @"
the interactive menu needs a terminal, and this one has no input attached.
  Say what to install instead, for example:
    .\foxprivacy.ps1 -Profile standard
"@
    }

    $standard = Get-PresetIds -Features $Features -Preset 'standard'
    $strict = Get-PresetIds -Features $Features -Preset 'strict'
    $selected = @($standard)

    while ($true) {
        Write-Host ''
        Write-Host "FoxPrivacy $FoxPrivacyVersion" -ForegroundColor White -NoNewline
        Write-Host "  $TargetPath" -ForegroundColor DarkGray
        Write-Host ''
        for ($i = 0; $i -lt $Features.Count; $i++) {
            $f = $Features[$i]
            if ($selected -contains $f.id) { $mark = 'x' } else { $mark = ' ' }
            Write-Host ("{0,3} " -f ($i + 1)) -ForegroundColor Blue -NoNewline
            Write-Host "[$mark] " -NoNewline
            Write-Host ("{0,-26} {1}" -f $f.id, $f.name)
            if ($f.cost) { Write-Host ("        cost: {0}" -f $f.cost) -ForegroundColor Yellow }
        }
        Write-Host ''
        Write-Host " $($selected.Count) enabled" -ForegroundColor White
        Write-Host ' number toggle   s standard   t strict   a all   n none'
        Write-Host ' d details   p preview json   i install   q quit'
        Write-Host ''

        $choice = Read-Host '>'
        switch -Regex ($choice) {
            '^[qQ]?$' { return }
            '^[sS]$'  { $selected = @($standard) }
            '^[tT]$'  { $selected = @($strict) }
            '^[aA]$'  { $selected = @($Features | ForEach-Object { $_.id }) }
            '^[nN]$'  { $selected = @() }
            '^[dD]$'  {
                Write-Host ''
                foreach ($f in $Features) {
                    if ($selected -notcontains $f.id) { continue }
                    Write-Host " $($f.id)" -ForegroundColor White
                    Write-Host "   $($f.summary)"
                }
                Write-Host ''
            }
            '^[pP]$' {
                Write-Host ''
                Write-Host (Build-PolicyJson -Features $Features -Selected (Sort-Selection $Features $selected))
                Write-Host ''
            }
            '^[iI]$' {
                if ($selected.Count -eq 0) { Write-Warn 'nothing selected'; continue }
                $ordered = Sort-Selection -Features $Features -Selected $selected
                $prof = 'custom'
                if (($ordered -join ' ') -eq ((Sort-Selection $Features $standard) -join ' ')) { $prof = 'standard' }
                if (($ordered -join ' ') -eq ((Sort-Selection $Features $strict) -join ' ')) { $prof = 'strict' }
                Write-Host ''
                Invoke-Install -Features $Features -Prof $prof -Selected $ordered -TargetPath $TargetPath
                return
            }
            '^[0-9]+$' {
                $n = [int]$choice
                if ($n -ge 1 -and $n -le $Features.Count) {
                    $id = $Features[$n - 1].id
                    if ($selected -contains $id) { $selected = @($selected | Where-Object { $_ -ne $id }) }
                    else { $selected = @($selected) + $id }
                } else { Write-Warn "not a choice: $choice" }
            }
            default { Write-Warn "not a choice: $choice" }
        }
    }
}

# ------------------------------------------------------------------- cli ----

function Show-Usage {
    Write-Host @"
FoxPrivacy $FoxPrivacyVersion - Firefox privacy configuration

  Run with no arguments for an interactive menu.
  Installing needs an Administrator PowerShell.

  .\foxprivacy.ps1 [options]

OPTIONS
  -Interactive        Pick features from a menu
  -Profile NAME       Install a preset: standard (default) or strict
  -Enable IDS         Comma separated feature ids to add to the profile
  -Disable IDS        Comma separated feature ids to remove from the profile
  -List               Show every feature and what it costs
  -Verify             Report whether the configuration is still installed
  -Uninstall          Restore what was there before FoxPrivacy
  -DryRun             Print what would change and exit
  -Target PATH        Write somewhere other than the default
  -Force              Proceed even if the installed file was modified
  -Version            Print the version
  -Help               This text

EXAMPLES
  .\foxprivacy.ps1
  .\foxprivacy.ps1 -Profile standard
  .\foxprivacy.ps1 -Profile strict -Disable captive-portal
  .\foxprivacy.ps1 -List
  .\foxprivacy.ps1 -Verify
  .\foxprivacy.ps1 -Uninstall

VERIFYING
  Restart Firefox and open about:policies. The Errors tab must be empty and
  the Active tab lists what is in effect. Nothing else proves Firefox accepted
  the configuration.
"@
}

function Invoke-Main {
    if ($Help) { Show-Usage; return 0 }
    if ($Version) { Write-Host $FoxPrivacyVersion; return 0 }

    $features = @(Read-Features -Lines (Get-Manifest))
    if ($features.Count -eq 0) { Stop-WithError 'the feature manifest is empty' }

    if ($List) { Invoke-List -Features $features; return 0 }

    if ($Target) { $targetPath = $Target } else { $targetPath = Get-DefaultTarget }

    if ($Verify) { return (Invoke-Verify -TargetPath $targetPath) }
    if ($Uninstall) { Invoke-Uninstall -TargetPath $targetPath; return 0 }

    $noArgs = -not ($Interactive -or $Enable -or $Disable -or $DryRun -or
                    $ProfileName -or $Target)

    if ($Interactive -or $noArgs) {
        Invoke-Interactive -Features $features -TargetPath $targetPath
        return 0
    }

    if (-not $ProfileName) { $ProfileName = 'standard' }

    $presetNames = Get-PresetNames -Features $features
    if ($presetNames -notcontains $ProfileName) {
        Stop-WithError "unknown profile: $ProfileName. Known profiles: $($presetNames -join ' ')"
    }

    $selected = @(Get-PresetIds -Features $features -Preset $ProfileName)
    $allIds = @($features | ForEach-Object { $_.id })

    foreach ($id in @($Enable -split ',' | Where-Object { $_ })) {
        $id = $id.Trim()
        if ($allIds -notcontains $id) { Stop-WithError "unknown feature: $id. Run -List to see them." }
        if ($selected -notcontains $id) { $selected += $id }
    }
    foreach ($id in @($Disable -split ',' | Where-Object { $_ })) {
        $id = $id.Trim()
        if ($allIds -notcontains $id) { Stop-WithError "unknown feature: $id. Run -List to see them." }
        $selected = @($selected | Where-Object { $_ -ne $id })
    }

    $prof = $ProfileName
    if ($Enable -or $Disable) { $prof = 'custom' }

    Invoke-Install -Features $features -Prof $prof `
        -Selected (Sort-Selection -Features $features -Selected $selected) -TargetPath $targetPath
    return 0
}

exit (Invoke-Main)
