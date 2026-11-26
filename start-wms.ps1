[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PgBase = Join-Path $env:LOCALAPPDATA "wms-postgres"
$PgBin = Join-Path $PgBase "pgsql\bin"
$PgData = Join-Path $PgBase "data"
$PgLog = Join-Path $PgBase "postgres.log"
$CargoBin = Join-Path $env:USERPROFILE ".cargo\bin"

if (Test-Path $CargoBin) {
    $env:PATH = "$CargoBin;$env:PATH"
}
if (Test-Path $PgBin) {
    $env:PATH = "$PgBin;$env:PATH"
}

function Load-DotEnvFile {
    param([string]$FilePath)
    $vars = @{}
    if (-not (Test-Path $FilePath)) { return $vars }
    foreach ($line in Get-Content -Path $FilePath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $idx = $trimmed.IndexOf("=")
        if ($idx -le 0) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $vars[$key] = $val
    }
    return $vars
}

Write-Host "[1/3] PostgreSQL 확인 및 시작 중..." -ForegroundColor Cyan
$pgCtl = Join-Path $PgBin "pg_ctl.exe"
$pgIsReady = Join-Path $PgBin "pg_isready.exe"
if (-not (Test-Path $pgCtl)) {
    throw "PostgreSQL이 설치되어 있지 않습니다: $pgCtl"
}

$pgReady = $false
if (Test-Path $pgIsReady) {
    & $pgIsReady -h 127.0.0.1 -p 5432 -q 2>$null
    if ($LASTEXITCODE -eq 0) { $pgReady = $true }
}

if (-not $pgReady) {
    if (-not (Test-Path $PgData)) {
        throw "PostgreSQL 데이터 폴더가 없습니다: $PgData"
    }
    $pidFile = Join-Path $PgData "postmaster.pid"
    if (Test-Path $pidFile) {
        $oldPidLine = (Get-Content $pidFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($oldPidLine -match '^\d+$') {
            $oldProc = Get-Process -Id ([int]$oldPidLine) -ErrorAction SilentlyContinue
            if (-not $oldProc -or $oldProc.ProcessName -ne "postgres") {
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Process -FilePath $pgCtl -ArgumentList @("-D", "`"$PgData`"", "-l", "`"$PgLog`"", "start") -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) {
        & $pgIsReady -h 127.0.0.1 -p 5432 -q 2>$null
        if ($LASTEXITCODE -eq 0) { $pgReady = $true; break }
        Start-Sleep -Milliseconds 500
    }
}

if (-not $pgReady) {
    throw "PostgreSQL이 포트 5432에서 응답하지 않습니다. 로그를 확인하세요: $PgLog"
}
Write-Host "  PostgreSQL 실행 중 (127.0.0.1:5432)" -ForegroundColor Green

Write-Host "[2/3] Rust API 서버 준비 및 시작 중 (포트 8080)..." -ForegroundColor Cyan
$RustDir = Join-Path $RootDir "rust-backend"
$rustEnv = Load-DotEnvFile (Join-Path $RustDir ".env")
$rustLocalEnv = Load-DotEnvFile (Join-Path $RustDir ".env.local")
foreach ($k in $rustLocalEnv.Keys) { $rustEnv[$k] = $rustLocalEnv[$k] }

if (-not $rustEnv["SUPER_ADMIN_PASSWORD"]) {
    throw "rust-backend\.env 파일에 SUPER_ADMIN_PASSWORD가 설정되어 있지 않습니다."
}

Get-Process -Name "wms-api" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($port in @(8080, 3000)) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
    }
}

$ReleaseExe = Join-Path $RustDir "target\release\wms-api.exe"
$DebugExe = Join-Path $RustDir "target\debug\wms-api.exe"
$RustSrc = Join-Path $RustDir "src\main.rs"
$RustExe = $null

if (Test-Path $ReleaseExe) {
    if ((Get-Item $ReleaseExe).LastWriteTimeUtc -ge (Get-Item $RustSrc).LastWriteTimeUtc) {
        $RustExe = $ReleaseExe
    }
}
if (-not $RustExe -and (Test-Path $DebugExe)) {
    if ((Get-Item $DebugExe).LastWriteTimeUtc -ge (Get-Item $RustSrc).LastWriteTimeUtc) {
        $RustExe = $DebugExe
    }
}

if (-not $RustExe) {
    Write-Host "  Rust 백엔드 빌드 중 (최초 1회는 몇 분 걸릴 수 있습니다)..." -ForegroundColor Yellow
    Push-Location $RustDir
    try {
        & cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "Rust 백엔드 빌드에 실패했습니다." }
    } finally {
        Pop-Location
    }
    $RustExe = $ReleaseExe
}

$ApiProc = Start-Process -FilePath $RustExe -WorkingDirectory $RustDir -PassThru -NoNewWindow
try {
    $apiReady = $false
    for ($i = 0; $i -lt 40; $i++) {
        if ($ApiProc.HasExited) {
            throw "Rust API 서버가 시작 직후 종료되었습니다 (종료 코드: $($ApiProc.ExitCode))."
        }
        try {
            $res = Invoke-WebRequest -Uri "http://127.0.0.1:8080/health" -UseBasicParsing -TimeoutSec 2
            if ($res.StatusCode -eq 200) { $apiReady = $true; break }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $apiReady) {
        throw "Rust API 서버(/health)가 응답하지 않습니다."
    }
    Write-Host "  Rust API 실행 중 (http://localhost:8080, PID: $($ApiProc.Id))" -ForegroundColor Green

    Write-Host "[3/3] Next.js 프론트엔드 시작 중 (포트 3000)..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "  AI Native WMS 실행 완료!" -ForegroundColor Green
    Write-Host "  홈페이지 주소: http://localhost:3000" -ForegroundColor White
    Write-Host "  종료하려면 이 창에서 Ctrl+C 를 누르거나 stop-wms.bat 실행" -ForegroundColor Gray
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""

    $browserJob = Start-Job -ScriptBlock {
        for ($i = 0; $i -lt 60; $i++) {
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:3000/login" -UseBasicParsing -TimeoutSec 2
                if ($r.StatusCode -eq 200) {
                    Start-Process "http://localhost:3000" | Out-Null
                    break
                }
            } catch {
                Start-Sleep -Milliseconds 500
            }
        }
    }

    Remove-Item Env:PORT -ErrorAction SilentlyContinue
    Push-Location (Join-Path $RootDir "frontend")
    try {
        & npm.cmd run dev
    } finally {
        Pop-Location
        Remove-Job -Job $browserJob -Force -ErrorAction SilentlyContinue
    }
} finally {
    if ($ApiProc -and -not $ApiProc.HasExited) {
        Write-Host "Rust API 서버(PID $($ApiProc.Id)) 종료 중..." -ForegroundColor Yellow
        Stop-Process -Id $ApiProc.Id -Force -ErrorAction SilentlyContinue
    }
}
