# =============================================================================
# jtag_boot.ps1 -- watch the board's UART during a JTAG boot and drive U-Boot.
#
# Usage (from repo root):
#     powershell -ExecutionPolicy Bypass -File scripts\jtag_boot.ps1
#     # then, in another window:  xsdb.bat scripts\jtag_boot.tcl
#
# The Genesys ZU's FTDI bridge exposes several channels; channel A is JTAG and
# one of the others is the PS UART. Rather than hardcode a COM port (it moves
# between machines and reboots), this watches every FTDI-backed port and acts
# on whichever one starts talking. Non-FTDI ports are left alone.
#
# It interrupts autoboot (there is no SD card to boot from) and issues booti
# with the ramdisk, using U-Boot's own default load addresses.
# =============================================================================
param(
    [string]$KernelAddr  = "0x18000000",
    [string]$FdtAddr     = "0x40000000",
    [string]$RamdiskAddr = "0x02100000",
    [string]$RamdiskFile = "build\jtag\core-image-minimal-genesys-zu3eg.rootfs.cpio.gz",
    [int]$TimeoutSec     = 300,
    [string]$LogDir      = "build\jtag"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $RamdiskFile)) { throw "Ramdisk not found: $RamdiskFile" }
$rsize = "0x{0:x}" -f (Get-Item $RamdiskFile).Length
$bootCmd = "booti $KernelAddr ${RamdiskAddr}:${rsize} $FdtAddr"
Write-Host "Boot command: $bootCmd"

# FTDI-backed COM ports only.
$ftdi = Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.Name -match 'COM(\d+)' -and $_.DeviceID -like 'FTDIBUS*' } |
        ForEach-Object { if ($_.Name -match 'COM(\d+)') { "COM$($Matches[1])" } }

if (-not $ftdi) { throw "No FTDI COM ports found. Is the board connected and powered?" }
Write-Host "Watching: $($ftdi -join ', ')"

$ports = @{}
foreach ($name in $ftdi) {
    try {
        $p = New-Object System.IO.Ports.SerialPort $name, 115200, 'None', 8, 'One'
        $p.ReadTimeout = 200; $p.NewLine = "`n"; $p.Open()
        $ports[$name] = @{ Port = $p; Buf = ""; Log = Join-Path $LogDir "uart-$name.log" }
        Set-Content -Path $ports[$name].Log -Value "" -Encoding utf8
    } catch { Write-Host "  (skipping $name : $($_.Exception.Message))" }
}
if ($ports.Count -eq 0) { throw "Could not open any FTDI port." }

$deadline    = (Get-Date).AddSeconds($TimeoutSec)
$interrupted = $false
$booted      = $false

try {
    while ((Get-Date) -lt $deadline) {
        foreach ($name in @($ports.Keys)) {
            $st = $ports[$name]
            try { $chunk = $st.Port.ReadExisting() } catch { $chunk = "" }
            if (-not $chunk) { continue }

            Write-Host -NoNewline $chunk
            Add-Content -Path $st.Log -Value $chunk -NoNewline -Encoding utf8
            $st.Buf += $chunk
            if ($st.Buf.Length -gt 8000) { $st.Buf = $st.Buf.Substring($st.Buf.Length - 4000) }

            # 1. Stop autoboot: there is no SD card, so let it not waste time.
            if (-not $interrupted -and $st.Buf -match 'Hit any key to stop autoboot') {
                Start-Sleep -Milliseconds 200
                $st.Port.Write("`r")
                $interrupted = $true
                Write-Host "`n[jtag_boot] autoboot interrupted on $name"
            }

            # 2. At the prompt, boot the RAM rootfs.
            if (-not $booted -and $st.Buf -match '(ZynqMP|U-Boot)>\s*$') {
                Start-Sleep -Milliseconds 300
                $st.Port.Write("$bootCmd`r")
                $booted = $true
                Write-Host "`n[jtag_boot] sent: $bootCmd"
                $st.Buf = ""
            }

            # 3. Done when the kernel reaches a login prompt.
            if ($booted -and $st.Buf -match 'login:') {
                Write-Host "`n[jtag_boot] LOGIN PROMPT REACHED on $name"
                $deadline = (Get-Date).AddSeconds(5)
            }
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    foreach ($name in @($ports.Keys)) { try { $ports[$name].Port.Close() } catch {} }
    Write-Host "`n[jtag_boot] logs in $LogDir\uart-COM*.log"
}
