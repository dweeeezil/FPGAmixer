# =============================================================================
# uart_log.ps1 -- passively capture the board's UART console.
#
# Usage (from repo root):
#     powershell -ExecutionPolicy Bypass -File scripts\uart_log.ps1 -TimeoutSec 600
#
# Unlike scripts\jtag_boot.ps1 this NEVER writes to the port on its own, so a
# normal SD boot proceeds untouched. Use -Send to type a line once a pattern
# appears (e.g. -WaitFor 'login:' -Send 'root').
#
# The Genesys ZU's FTDI bridge exposes several channels (A is JTAG); this
# watches every FTDI-backed COM port and logs whichever one talks.
# =============================================================================
param(
    [int]$TimeoutSec  = 600,
    [string]$LogDir   = "build\sd",
    [string]$WaitFor  = "",
    [string]$Send     = "",
    [string]$QuietFor = ""
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$ftdi = Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.Name -match 'COM(\d+)' -and $_.DeviceID -like 'FTDIBUS*' } |
        ForEach-Object { if ($_.Name -match 'COM(\d+)') { "COM$($Matches[1])" } }
if (-not $ftdi) { throw "No FTDI COM ports found. Is the board connected and powered?" }
Write-Host "Watching: $($ftdi -join ', ')  (timeout ${TimeoutSec}s)"

$ports = @{}
foreach ($name in $ftdi) {
    try {
        $p = New-Object System.IO.Ports.SerialPort $name, 115200, 'None', 8, 'One'
        $p.ReadTimeout = 200; $p.NewLine = "`n"; $p.Open()
        $ports[$name] = @{ Port = $p; Buf = ""; Log = Join-Path $LogDir "uart-$name.log"; Sent = $false }
        Set-Content -Path $ports[$name].Log -Value "" -Encoding utf8
    } catch { Write-Host "  (skipping $name : $($_.Exception.Message))" }
}
if ($ports.Count -eq 0) { throw "Could not open any FTDI port." }

$deadline = (Get-Date).AddSeconds($TimeoutSec)
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

            if ($WaitFor -and $Send -and -not $st.Sent -and $st.Buf -match $WaitFor) {
                Start-Sleep -Milliseconds 500
                $st.Port.Write("$Send`r")
                $st.Sent = $true
                Write-Host "`n[uart_log] sent '$Send' on $name"
                $st.Buf = ""
            }
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    foreach ($name in @($ports.Keys)) { try { $ports[$name].Port.Close() } catch {} }
    Write-Host "`n[uart_log] logs in $LogDir\uart-COM*.log"
}
