#Requires -Version 5.1
<#
  start-local.ps1 — one-command local run for RAFNet.
  - Starts the backend (FastAPI, real RAFNet model) on http://127.0.0.1:8000
  - Starts the frontend (Vite + React) on http://127.0.0.1:3000
  - Loads repo-root .env for the backend (never prints values)
  - Waits for GET /api/health, then prints the URLs.
  First-time setup: see LOCAL_RUN.md.
#>
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

function Get-PortListenerIds([int]$Port) {
  $listenerIds = @()
  try {
    $listenerIds = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
      Select-Object -ExpandProperty OwningProcess -Unique)
  } catch {
    foreach ($line in @(netstat -ano -p tcp 2>$null)) {
      if ($line -match 'LISTENING' -and $line -match ":$Port\s") {
        $candidate = ($line -split '\s+')[-1]
        if ($candidate -match '^\d+$') { $listenerIds += [int]$candidate }
      }
    }
    $listenerIds = @($listenerIds | Select-Object -Unique)
  }
  return @($listenerIds)
}

function Get-ListenerProcess([int]$ProcessId) {
  $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  if ($null -eq $cim) {
    return [pscustomobject]@{ Id = $ProcessId; Name = "unknown"; Path = ""; CommandLine = "" }
  }
  return [pscustomobject]@{
    Id = $ProcessId
    Name = [string]$cim.Name
    Path = [string]$cim.ExecutablePath
    CommandLine = [string]$cim.CommandLine
  }
}

function Format-ListenerConflict([int]$Port, $Proc) {
  $where = if ($Proc.Path) { " $($Proc.Path)" } else { "" }
  return "port $Port - PID $($Proc.Id) ($($Proc.Name)$where)"
}

function Assert-PortsFree() {
  $conflicts = @()
  foreach ($port in @(8000, 3000)) {
    foreach ($procId in @(Get-PortListenerIds $port)) {
      $proc = Get-ListenerProcess $procId
      $isRafnetBackend = (($port -eq 8000) -and ($proc.CommandLine -match 'uvicorn') -and ($proc.CommandLine -match 'rafnet') -and ($procId -ne $PID))
      if ($isRafnetBackend) {
        Write-Host "Port $port is held by a stale RAFNet uvicorn (PID $procId); stopping only that process." -ForegroundColor Yellow
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 750
        if (@(Get-PortListenerIds $port) -contains $procId) {
          $conflicts += (Format-ListenerConflict $port $proc) + " (could not be stopped)"
        }
        continue
      }
      $conflicts += Format-ListenerConflict $port $proc
    }
  }
  if ($conflicts.Count -gt 0) {
    Write-Host "Cannot start RAFNet: port 8000 and/or 3000 is already in use." -ForegroundColor Red
    foreach ($conflict in $conflicts) { Write-Host "  $conflict" }
    Write-Host "Stop the listed process(es) and re-run. Only a RAFNet uvicorn on :8000 is stopped automatically." -ForegroundColor Red
    exit 1
  }
}

Assert-PortsFree

function Sanitize-VenvPath([string]$Raw) {
  if ($null -eq $Raw) { return "" }
  $s = "$Raw".Trim()
  # Strip surrounding single/double quotes repeatedly (copy-paste artifacts).
  while ($s.Length -ge 2 -and (($s.StartsWith('"') -and $s.EndsWith('"')) -or ($s.StartsWith("'") -and $s.EndsWith("'")))) {
    $s = $s.Substring(1, $s.Length - 2).Trim()
  }
  # Remove angle brackets (never valid in a Windows venv path; blocks "<venv>" placeholders).
  $s = $s.Replace("<", "").Replace(">", "").Trim()
  # Strip any remaining surrounding quotes after bracket removal.
  while ($s.Length -ge 2 -and (($s.StartsWith('"') -and $s.EndsWith('"')) -or ($s.StartsWith("'") -and $s.EndsWith("'")))) {
    $s = $s.Substring(1, $s.Length - 2).Trim()
  }
  return $s
}

# Real-model runtime: repo .venv by default. Override with $env:RAFNET_VENV
# (path to a venv dir) when .venv's native stack is blocked — e.g. sklearn's
# _liblinear DLL denied by Application Control (see MOCK_DIAGNOSIS.md).
$DefaultVenvDir = Join-Path $Root ".venv"
$RawVenv = Sanitize-VenvPath $env:RAFNET_VENV
$VenvDir = if ([string]::IsNullOrWhiteSpace($RawVenv)) { $DefaultVenvDir } else { $RawVenv }
if ($VenvDir -match '[\\/]python\.exe$' -and (Test-Path -LiteralPath $VenvDir)) {
  $VenvDir = Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($VenvDir)))
}
if (-not (Test-Path -LiteralPath $VenvDir)) {
  Write-Host "RAFNET_VENV '$VenvDir' not found; falling back to default $DefaultVenvDir." -ForegroundColor Yellow
  $VenvDir = $DefaultVenvDir
}
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path -LiteralPath $VenvPython)) {
  # Second chance: the raw value may have pointed at python.exe itself or a broken dir.
  if ($VenvDir -ne $DefaultVenvDir -and (Test-Path -LiteralPath (Join-Path $DefaultVenvDir "Scripts\python.exe"))) {
    Write-Host "Falling back to default venv python (custom RAFNET_VENV invalid)." -ForegroundColor Yellow
    $VenvDir = $DefaultVenvDir
    $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
  }
}
Write-Host "Using python: $VenvPython (RAFNET_VENV raw='$env:RAFNET_VENV' sanitized='$VenvDir')"
try { & $VenvPython --version } catch { }
$FrontendDir = Join-Path $Root "frontend"

if (-not (Test-Path -LiteralPath $VenvPython)) {
  Write-Host "Missing venv python at $VenvPython. First-time setup (Windows PowerShell):" -ForegroundColor Yellow
  Write-Host "  py -3.12 -m venv .venv"
  Write-Host "  .\.venv\Scripts\pip.exe install --no-cache-dir torch torchaudio --index-url https://download.pytorch.org/whl/cpu"
  Write-Host "  .\.venv\Scripts\pip.exe install --no-cache-dir -r requirements-ml.txt"
  Write-Host "  .\.venv\Scripts\pip.exe install --no-cache-dir -e . pytest httpx"
  Write-Host "  Or set `$env:RAFNET_VENV to a working ML venv (see MOCK_DIAGNOSIS.md)."
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $VenvDir "pyvenv.cfg"))) {
  Write-Host "Refusing to start: '$VenvDir' is not a Python virtual environment (missing pyvenv.cfg)." -ForegroundColor Red
  exit 1
}
& $VenvPython -c "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)"
if ($LASTEXITCODE -ne 0) {
  Write-Host "Refusing to start: $VenvPython is not a virtual-environment interpreter." -ForegroundColor Red
  exit 1
}
# Preflight: the real model needs torch + transformers + working sklearn.
# Fail fast with the exact missing piece instead of booting a dead backend.
& $VenvPython -c "import torch, transformers; from sklearn.linear_model import LogisticRegression; print('ml stack ok')"
if ($LASTEXITCODE -ne 0) {
  Write-Host "ML stack broken in $VenvDir (see error above)." -ForegroundColor Red
  Write-Host "Fix: use a venv where torch+transformers+sklearn import cleanly,"
  Write-Host "then re-run with `$env:RAFNET_VENV='<that venv dir>'. Mock mode stays"
  Write-Host "opt-in only: start the backend manually with `$env:MOCK_INFERENCE='true'."
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $FrontendDir "node_modules"))) {
  Write-Host "Missing frontend/node_modules. Run: cd frontend; npm install" -ForegroundColor Yellow
  exit 1
}

# Load repo-root .env into this process (backend servers inherit it).
$DotEnv = Join-Path $Root ".env"
$dotEnvCount = 0
if (Test-Path -LiteralPath $DotEnv) {
  foreach ($line in Get-Content -LiteralPath $DotEnv) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#") -or (-not ($t.Contains("=")))) { continue }
    $k = $t.Substring(0, $t.IndexOf("=")).Trim()
    $v = $t.Substring($t.IndexOf("=") + 1).Trim()
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
    $dotEnvCount++
  }
  Write-Host "Loaded .env for backend ($dotEnvCount variable(s); values not printed, inherited by child processes)."
} else {
  Write-Host "No .env found; using .env.example defaults. Copy .env.example to .env to customize." -ForegroundColor Yellow
  $env:MOCK_INFERENCE = "false"
  $env:RAFNET_DEVICE = "cpu"
  $env:SOC_REQUIRE_AUTH = "false"
  $env:CORS_ORIGINS = "http://localhost:3000,http://localhost:5173,http://localhost:8000"
}
# Mock is strictly opt-in: only the literal value "true" enables it.
$MockFlag = ("$env:MOCK_INFERENCE").Trim().ToLower()
if ($MockFlag -eq "true") {
  Write-Host "MOCK_INFERENCE=true — backend will use MockVoiceModel (dev only, never for evaluation)." -ForegroundColor Yellow
} else {
  $env:MOCK_INFERENCE = "false"
  Write-Host "MOCK_INFERENCE=false — real RAFNet model (mock disabled)."
}

$SrcDir = Join-Path $Root "src"
Write-Host "Starting backend on :8000 with $VenvPython ..."
$QuotedVenvPython = "'" + $VenvPython.Replace("'", "''") + "'"
$backendCommand = "& $QuotedVenvPython -m uvicorn rafnet.api.main:app --host 127.0.0.1 --port 8000"
Start-Process -FilePath "powershell.exe" -ArgumentList @(
  "-NoProfile", "-NoExit", "-Command", $backendCommand
) -WorkingDirectory $SrcDir -WindowStyle Normal

Write-Host "Starting frontend on :3000 ..."
Start-Process -FilePath "cmd.exe" -ArgumentList @("/c npm run dev") -WorkingDirectory $FrontendDir -WindowStyle Normal

Write-Host "Waiting for backend GET /api/health (first boot downloads WavLM, can take minutes) ..."
$deadline = (Get-Date).AddMinutes(10)
$healthy = $false
while ((Get-Date) -lt $deadline) {
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:8000/api/health" -TimeoutSec 300
    Write-Host ("Backend health: " + ($r | ConvertTo-Json -Compress))
    $healthy = $true
    break
  } catch {
    Start-Sleep -Seconds 5
  }
}
if (-not $healthy) {
  Write-Host "Backend did not become healthy within 10 minutes. Check the backend window logs." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "RAFNet is running locally:" -ForegroundColor Green
Write-Host "  Backend:  http://127.0.0.1:8000  (docs: http://127.0.0.1:8000/docs)"
Write-Host "  Frontend: http://127.0.0.1:3000  (login, then Analyze)"
