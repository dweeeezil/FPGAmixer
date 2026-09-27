# =============================================================================
# xsim_regress.ps1 -- every testbench, with XSim (Vivado 2026.1), on Windows
#
# The XSim counterpart of scripts/sim.mk (Icarus): the same targets and file
# lists; keep the two in step. Each TB is compiled in a FRESH directory,
# build/xsim_regress/<tb>, because a reused xsim.dir once made xvlog hang
# (Phase 9, P9.A4), and each step has a time limit.
#
# Usage (PowerShell, from the repo root):
#   .\scripts\xsim_regress.ps1                 # all
#   .\scripts\xsim_regress.ps1 matrix regs     # some, by sim.mk target name
# Prints one PASS/FAIL line per TB (the TB's own verdict line) and a summary;
# exits 1 if any TB fails or times out.
# =============================================================================
param([string[]]$Only)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path
$rtl  = "$root\src\rtl"
$sim  = "$root\src\sim"

$mixcore = @("pcm_matrix_pkg","pcm_pack2stream","pcm_stream2pack","pcm_matrix","mixer_core") |
           ForEach-Object { "$rtl\$_.sv" }
$coreRtl = $mixcore + (@("coef_flat_reader","i2s_receiver","i2s_transmitter","i2s_clock_divider",
                         "reset_sync","audio_clocking","i2s_port","oddr_out","fpgamixer_top") |
                       ForEach-Object { "$rtl\$_.sv" })

# target = @(top module, defines, files)
$targets = [ordered]@{
  rx          = @("tb_i2s_receiver",     "", @("$rtl\i2s_receiver.sv","$rtl\i2s_clock_divider.sv","$sim\tb_i2s_receiver.sv"))
  tx          = @("tb_i2s_transmitter",  "", @("$rtl\i2s_transmitter.sv","$rtl\i2s_clock_divider.sv","$sim\tb_i2s_transmitter.sv"))
  txphase     = @("tb_i2s_tx_pin_phase", "", @("$rtl\i2s_transmitter.sv","$rtl\i2s_clock_divider.sv","$sim\tb_i2s_tx_pin_phase.sv"))
  loopback    = @("tb_i2s_loopback",     "", @("$rtl\i2s_receiver.sv","$rtl\i2s_transmitter.sv","$rtl\i2s_clock_divider.sv","$sim\tb_i2s_loopback.sv"))
  matrix      = @("tb_pcm_matrix",       "", ($mixcore + @("$rtl\coef_flat_reader.sv","$sim\tb_pcm_matrix.sv")))
  matrix_rect = @("tb_pcm_matrix_rect",  "", ($mixcore + @("$rtl\coef_flat_reader.sv","$sim\pcm_stream_monitor.sv","$sim\tb_pcm_matrix_rect.sv")))
  stream      = @("tb_pcm_stream",       "", @("$rtl\pcm_pack2stream.sv","$rtl\pcm_stream2pack.sv","$sim\pcm_stream_monitor.sv","$sim\tb_pcm_stream.sv"))
  coefram     = @("tb_coef_bank_ram",    "", @("$rtl\coef_bank_ram.sv","$rtl\coef_flat_reader.sv","$sim\tb_coef_bank_ram.sv"))
  regs        = @("tb_matrix_regs",      "", ($mixcore + @("$rtl\coef_bank_ram.sv","$rtl\axil_coef_window.sv","$rtl\matrix_regs_axil.sv","$sim\tb_matrix_regs.sv")))
  link        = @("tb_pcm_link",         "", @("$rtl\async_fifo.sv","$rtl\pcm_link.sv","$sim\tb_pcm_link.sv"))
  mclk        = @("tb_media_clock_meter", "", @("$rtl\media_clock_meter.sv","$rtl\coef_bank_handoff.sv","$rtl\axil_stat_window.sv","$rtl\media_clock_stat_regs.sv","$sim\tb_media_clock_meter.sv"))
  linkstat    = @("tb_link_stat_regs",   "", @("$rtl\coef_bank_handoff.sv","$rtl\axil_stat_window.sv","$rtl\pcm_link_stat_regs.sv","$sim\tb_link_stat_regs.sv"))
  phase3      = @("tb_phase3_datapath",  "SIM_ODDR", ($coreRtl + @("$sim\clk_wiz_audio_stub.sv","$sim\tb_phase3_datapath.sv")))
  dynamic     = @("tb_phase3_dynamic",   "SIM_ODDR", ($coreRtl + @("$sim\clk_wiz_audio_stub.sv","$sim\tb_phase3_dynamic.sv")))
}

function Invoke-Limited([string]$dir, [scriptblock]$block, [object[]]$argsList, [int]$seconds) {
  $j = Start-Job -ScriptBlock $block -ArgumentList (@($dir) + $argsList)
  if (Wait-Job $j -Timeout $seconds) { $o = Receive-Job $j; Remove-Job $j; return ,$o }
  Stop-Job $j; Remove-Job $j -Force
  Get-Process xvlog, xelab, xsimk -ErrorAction SilentlyContinue | Stop-Process -Force
  return $null
}

$fails = 0
foreach ($name in $targets.Keys) {
  if ($Only -and ($Only -notcontains $name)) { continue }
  $top, $def, $files = $targets[$name]
  $dir = "$root\build\xsim_regress\$name"
  if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
  New-Item -ItemType Directory -Force $dir | Out-Null

  $comp = Invoke-Limited $dir {
      param($d, $def, $files)
      Set-Location $d
      $dargs = @(); if ($def) { $dargs = @("-d", $def) }
      xvlog -sv @dargs @files 2>&1 | Out-String
  } @($def, $files) 180
  if ($null -eq $comp -or $comp -match "ERROR:") {
      "{0,-12} FAIL (compile{1})" -f $name, $(if ($null -eq $comp) {" timed out"} else {""}); $fails++; continue
  }
  $run = Invoke-Limited $dir {
      param($d, $top)
      Set-Location $d
      $e = xelab $top -s snap -timescale 1ns/1ps 2>&1 | Out-String
      if ($e -match "ERROR:") { return "ELAB ERROR`n$e" }
      xsim snap -R 2>&1 | Out-String
  } @($top) 600
  if ($null -eq $run) { "{0,-12} FAIL (timed out)" -f $name; $fails++; continue }
  $verdict = ($run -split "`n" | Where-Object { $_ -match "PASS|FAIL" } | Select-Object -Last 1)
  if ($run -match "ELAB ERROR") { $verdict = "FAIL (elaboration)" }
  if (-not $verdict) { $verdict = "FAIL (no verdict line)" }
  if ($verdict -notmatch "PASS" -or $verdict -match "FAIL") { $fails++ }
  "{0,-12} {1}" -f $name, $verdict.Trim()
}
""
if ($fails -eq 0) { "ALL PASS" } else { "$fails FAILED"; exit 1 }
