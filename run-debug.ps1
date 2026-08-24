#!/usr/bin/env pwsh
# Run NeoStation in debug mode with build-time variables from .env.
# Usage: .\run-debug.ps1
# Or with a custom env file: .\run-debug.ps1 -EnvFile .\.env.local

param(
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
    Write-Error "Environment file not found: $EnvFile`nCreate it with: Copy-Item .env.example .env"
    exit 1
}

$lines = Get-Content $EnvFile
$requiredKeys = @(
    "SCREENSCRAPER_DEV_ID",
    "SCREENSCRAPER_DEV_PASSWORD"
)

foreach ($key in $requiredKeys) {
    $escapedKey = [Regex]::Escape($key)
    $line = $lines |
        Where-Object { $_ -match "^\s*$escapedKey\s*=" } |
        Select-Object -Last 1

    if ($null -eq $line) {
        Write-Error "Missing required key '$key' in $EnvFile."
        exit 1
    }

    $value = ($line -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Error "Required key '$key' is empty in $EnvFile."
        exit 1
    }
}

Write-Host "Loading environment from: $EnvFile" -ForegroundColor Cyan
Write-Host "ScreenScraper developer configuration is present (values hidden)." -ForegroundColor Green
flutter run --dart-define-from-file=$EnvFile @args
