# =============================================================================
# netsim_ltc.ps1 -- tb_ltc_decoder against ltc_decoder's SYNTHESIZED netlist
# (Vivado 2026.1, out of context, write_verilog -mode funcsim), on Windows.
#
# The FPGAmixer counterpart of the library's scripts/netsim.ps1: XSim runs the
# RTL as the standard says, and synthesis may build something else (the eq1
# fault, 2026-11-18). Also prints the block's resources.
#
# Usage (PowerShell, from the repo root): .\scripts\netsim_ltc.ps1
# "child exe not found" or a synth_design failure with no reason is Windows
# Defender: rerun.
# =============================================================================
$ErrorActionPreference = "Continue"
$root = (Resolve-Path "$PSScriptRoot\..").Path
$dir  = "$root\build\netsim\ltc"
$part = "xczu3eg-sfvc784-1-e"
if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
    Set-Content -Encoding ascii synth.tcl @(
        "read_verilog -sv {$root\src\rtl\ltc_decoder.sv}",
        "synth_design -top ltc_decoder -part $part -mode out_of_context",
        "report_utilization -file util.rpt",
        "write_verilog -force -mode funcsim net.v")
    vivado -mode batch -nojournal -nolog -source synth.tcl *> synth.log
    if (-not (Test-Path net.v)) { "ltc netlist: FAIL (synthesis: see $dir\synth.log)"; exit 1 }
    Select-String -Path util.rpt -Pattern "^\| (CLB LUTs|CLB Registers|Block RAM Tile|DSPs) " |
        Select-Object -First 4 | ForEach-Object { $_.Line }

    $g = & python "$root\src\sim\ltc_gen.py" --vectors $dir 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { "ltc netlist: FAIL (vectors)`n$g"; exit 1 }

    $c = (xvlog net.v 2>&1 | Out-String) + (xvlog -sv -i $dir "$root\src\sim\tb_ltc_decoder.sv" 2>&1 | Out-String)
    if ($c -match "ERROR:") { "ltc netlist: FAIL (compile)`n$c"; exit 1 }
    $e = xelab tb_ltc_decoder glbl -L unisims_ver -s snap -timescale 1ns/1ps 2>&1 | Out-String
    if ($e -match "ERROR:") { "ltc netlist: FAIL (elaboration)`n$e"; exit 1 }
    $run = xsim snap -R 2>&1 | Out-String
    if ($run -match "child exe not found") { $run = xsim snap -R 2>&1 | Out-String }   # Defender: once more
    Set-Content -Encoding ascii run.log $run
    $verdict = ($run -split "`n" | Where-Object { $_ -match "PASS|FAIL" } | Select-Object -Last 1)
    if (-not $verdict) { $verdict = "FAIL (no verdict line)" }
    "ltc netlist: " + $verdict.Trim()
    if ($verdict -notmatch "PASS" -or $verdict -match "FAIL") { exit 1 }
} finally { Pop-Location }
