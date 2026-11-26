[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "SilentlyContinue"
$PgBase = Join-Path $env:LOCALAPPDATA "wms-postgres"
$PgCtl = Join-Path $PgBase "pgsql\bin\pg_ctl.exe"
$PgData = Join-Path $PgBase "data"

Get-Process -Name "wms-api" -ErrorAction SilentlyContinue | Stop-Process -Force

foreach ($port in @(3000, 8080)) {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
    }
}

if ((Test-Path $PgCtl) -and (Test-Path $PgData)) {
    Start-Process -FilePath $PgCtl -ArgumentList @("-D", "`"$PgData`"", "stop", "-m", "fast") -Wait -WindowStyle Hidden
}

Write-Host "WMS 프론트엔드, Rust API, PostgreSQL 종료 완료." -ForegroundColor Green
