#!/usr/bin/env pwsh
# Wrapper script for the Hive CLI (Windows).
# Uses uv to run the hive command in the project's virtual environment.
#
# On Windows, User-level environment variables (set via quickstart.ps1) are
# stored in the registry but may not be loaded into the current terminal
# session (VS Code terminals, Windows Terminal tabs, etc.). This script
# explicitly loads them before running the agent — the Windows equivalent
# of Linux shells sourcing ~/.bashrc.

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Get-WorkingUvPath {
    # pyenv-win can expose a non-functional uv shim, so verify candidates first.
    $candidates = @()

    $commands = @(Get-Command uv -All -ErrorAction SilentlyContinue)
    foreach ($cmd in $commands) {
        if ($cmd.Source) {
            $candidates += $cmd.Source
        } elseif ($cmd.Definition) {
            $candidates += $cmd.Definition
        } elseif ($cmd.Name) {
            $candidates += $cmd.Name
        }
    }

    $defaultUvExe = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path $defaultUvExe) {
        $candidates += $defaultUvExe
    }

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $null = & $candidate --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $candidate
            }
        } catch {
            # Try the next candidate.
        }
    }

    return $null
}

# ── Validate project directory ──────────────────────────────────────

if ((Get-Location).Path -ne $ScriptDir) {
    Write-Error "hive must be run from the project directory.`nCurrent directory: $(Get-Location)`nExpected directory: $ScriptDir`n`nRun: cd $ScriptDir"
    exit 1
}

if (-not (Test-Path (Join-Path $ScriptDir "pyproject.toml")) -or -not (Test-Path (Join-Path $ScriptDir "core"))) {
    Write-Error "Not a valid Hive project directory: $ScriptDir"
    exit 1
}

if (-not (Test-Path (Join-Path $ScriptDir ".venv"))) {
    Write-Error "Virtual environment not found. Run .\quickstart.ps1 first to set up the project."
    exit 1
}

# ── Ensure uv is available ──────────────────────────────────────────

$uvExe = Get-WorkingUvPath
if (-not $uvExe) {
    Write-Error "uv is not installed or is not runnable. Run .\quickstart.ps1 first."
    exit 1
}

# ── Load environment variables from Windows Registry ────────────────
# Windows stores User-level env vars in the registry. New terminal
# sessions may not have them (especially VS Code integrated terminals).
# Load them explicitly so agents can find their API keys.

$configPath = Join-Path (Join-Path $env:USERPROFILE ".hive") "configuration.json"
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $envVarName = $config.llm.api_key_env_var
        if ($envVarName) {
            $val = [System.Environment]::GetEnvironmentVariable($envVarName, "User")
            if ($val -and -not (Test-Path "Env:\$envVarName" -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Env:\$envVarName" -Value $val
            }
        }
    } catch {
        # Non-fatal: agent may still work if env vars are already set
    }
}

# Load HIVE_CREDENTIAL_KEY for encrypted credential store
if (-not $env:HIVE_CREDENTIAL_KEY) {
    # 1. Windows User env var (legacy quickstart installs)
    $credKey = [System.Environment]::GetEnvironmentVariable("HIVE_CREDENTIAL_KEY", "User")
    if ($credKey) {
        $env:HIVE_CREDENTIAL_KEY = $credKey
    } else {
        # 2. File-based storage (new quickstart + matches quickstart.sh)
        $credKeyFile = Join-Path $env:USERPROFILE ".hive\secrets\credential_key"
        if (Test-Path $credKeyFile) {
            $env:HIVE_CREDENTIAL_KEY = (Get-Content $credKeyFile -Raw).Trim()
        }
    }
}

# ── Run the Hive CLI ────────────────────────────────────────────────
# PYTHONUTF8=1: use UTF-8 for default encoding (fixes charmap decode errors on Windows)
$env:PYTHONUTF8 = "1"
& $uvExe run hive @args
