# mutate_sv.ps1 -- run XSim targets (xsim_regress.ps1 names) against source
# mutants in a temp copy of src/ and scripts/ (%TEMP%\fpgamixer-mutcopy).
# Usage: scripts\mutate_sv.ps1 <mutants.json> <target> [<target> ...]
# mutants.json: [ {"name": "...", "file": "src/rtl/x.sv", "old": "...", "new": "..."} ]
# "old" must occur exactly once; "\n" in it also matches CRLF files.
# The unmutated baseline runs first and must pass. A Defender "child exe not
# found" is retried once and otherwise reported as a TOOL FAILURE, never as a
# verdict. (Hardening 2026-10, Phase 15.)
param([string]$Spec, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Targets)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$work = Join-Path $env:TEMP "fpgamixer-mutcopy"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory $work | Out-Null
foreach ($d in "src", "scripts") { Copy-Item -Recurse "$repo\$d" "$work\$d" }

function Run-Targets {
    $out = & "$work\scripts\xsim_regress.ps1" @Targets 2>&1 | Out-String
    return $out
}

$base = Run-Targets
if ($base -notmatch "ALL PASS") { "BASELINE FAILED:"; $base; exit 1 }
"baseline: ALL PASS"

$mutants = Get-Content $Spec -Raw | ConvertFrom-Json
$killed = 0; $total = 0
foreach ($m in $mutants) {
    $total++
    $path = Join-Path $work $m.file
    $orig = [IO.File]::ReadAllText($path)
    $old, $new = $m.old, $m.new
    if (-not $orig.Contains($old)) { $old = $old.Replace("`n", "`r`n"); $new = $new.Replace("`n", "`r`n") }
    $n = ($orig.Split([string[]]@($old), [StringSplitOptions]::None)).Count - 1
    if ($n -ne 1) { "{0,-40} BAD SPEC ({1} matches)" -f $m.name, $n; continue }
    [IO.File]::WriteAllText($path, $orig.Replace($old, $new))
    $out = Run-Targets
    [IO.File]::WriteAllText($path, $orig)
    if ($out -match "child exe not found") {
        $out = $null
        [IO.File]::WriteAllText($path, $orig.Replace($old, $new))
        $out = Run-Targets
        [IO.File]::WriteAllText($path, $orig)
    }
    if ($out -match "child exe not found") { "{0,-40} TOOL FAILURE (rerun)" -f $m.name; continue }
    if ($out -match "ALL PASS") { "{0,-40} SURVIVED" -f $m.name }
    else {
        $killed++
        $why = (($out -split "`n") | Where-Object { $_ -match "FAIL" } | Select-Object -First 1).Trim()
        "{0,-40} killed  ({1})" -f $m.name, $why
    }
}
"killed $killed / $total"
