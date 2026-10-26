# mutate_py.ps1 -- run Python unit tests against source mutants in a temp copy of tools/
# (%TEMP%\fpgamixer-mutpy); "\n" in "old" also matches CRLF files. (Hardening 2026-10.)
# Usage: mutate_py.ps1 <mutants.json> <test module or Class> [...]
# The unmutated baseline runs first and must pass.
param([string]$Spec, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Tests)
$ErrorActionPreference = "Continue"
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$work = Join-Path $env:TEMP "fpgamixer-mutpy"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory $work | Out-Null
Copy-Item -Recurse "$repo\tools" "$work\tools"

function Run-Tests {
    Push-Location "$work\tools"
    $out = & python -m unittest @Tests 2>&1 | Out-String
    Pop-Location
    return $out
}

$base = Run-Tests
if ($base -notmatch "(?m)^OK") { "BASELINE FAILED:"; $base; exit 1 }
"baseline: OK"

$mutants = Get-Content $Spec -Raw | ConvertFrom-Json
$killed = 0; $total = 0
foreach ($m in $mutants) {
    $total++
    $path = Join-Path $work $m.file
    $orig = [IO.File]::ReadAllText($path)
    $old = $m.old.Replace("`n", "`r`n"); if ($orig.Contains($m.old)) { $old = $m.old }
    $new = if ($old -eq $m.old) { $m.new } else { $m.new.Replace("`n", "`r`n") }
    $n = ($orig.Split([string[]]@($old), [StringSplitOptions]::None)).Count - 1
    if ($n -ne 1) { "{0,-45} BAD SPEC ({1} matches)" -f $m.name, $n; continue }
    [IO.File]::WriteAllText($path, $orig.Replace($old, $new))
    $out = Run-Tests
    [IO.File]::WriteAllText($path, $orig)
    if ($out -match "(?m)^OK") { "{0,-45} SURVIVED" -f $m.name }
    else {
        $killed++
        $why = (($out -split "`n") | Where-Object { $_ -match "^(FAIL|ERROR):" } | Select-Object -First 1)
        "{0,-45} killed  ({1})" -f $m.name, ("$why".Trim())
    }
}
"killed $killed / $total"
