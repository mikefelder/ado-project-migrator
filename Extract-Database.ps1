#Requires -Version 5.1
<#
.SYNOPSIS
    Extract a SQL Server database to a .dacpac file using SqlPackage.exe.

.DESCRIPTION
    Interactive script that:
    1. Locates or prompts for the SqlPackage.exe path
    2. Prompts for SQL Server connection details (server, authentication, credentials)
    3. Enumerates databases on the server and lets you pick one
    4. Extracts the selected database to a .dacpac file

.EXAMPLE
    ./Extract-Database.ps1
    ./Extract-Database.ps1 -OutputDir "C:\Exports"
#>
[CmdletBinding()]
param(
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

# ── Banner ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          SQL DATABASE EXTRACTOR (SqlPackage)                ║" -ForegroundColor Cyan
Write-Host "║          Extract a database to .dacpac                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Locate SqlPackage.exe ────────────────────────────────────────────
Write-Host "  Step 1: Locating SqlPackage.exe..." -ForegroundColor Yellow
Write-Host ""

$sqlPackagePath = $null

# Common install locations
$searchPaths = @(
    "$env:ProgramFiles\Microsoft SQL Server\*\DAC\bin\SqlPackage.exe",
    "${env:ProgramFiles(x86)}\Microsoft SQL Server\*\DAC\bin\SqlPackage.exe",
    "$env:ProgramFiles\Microsoft Visual Studio\*\*\Common7\IDE\Extensions\Microsoft\SQLDB\DAC\SqlPackage.exe",
    "$env:USERPROFILE\.dotnet\tools\SqlPackage.exe",
    "$env:USERPROFILE\.dotnet\tools\sqlpackage.exe"
)

# Check PATH first
$inPath = Get-Command SqlPackage -ErrorAction SilentlyContinue
if ($inPath) {
    $sqlPackagePath = $inPath.Source
}
else {
    foreach ($pattern in $searchPaths) {
        $found = Get-Item $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) {
            $sqlPackagePath = $found.FullName
            break
        }
    }
}

if ($sqlPackagePath) {
    Write-Host "  Found SqlPackage at: $sqlPackagePath" -ForegroundColor Green
    Write-Host ""
    $useFound = Read-Host "  Use this path? (Y/n)"
    if ($useFound -eq 'n' -or $useFound -eq 'N') {
        $sqlPackagePath = $null
    }
}

if (-not $sqlPackagePath) {
    Write-Host "  SqlPackage.exe not found in common locations." -ForegroundColor DarkGray
    Write-Host "  You can install it via: dotnet tool install -g microsoft.sqlpackage" -ForegroundColor DarkGray
    Write-Host "  Or download from: https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-download" -ForegroundColor DarkGray
    Write-Host ""
    $sqlPackagePath = Read-Host "  Enter the full path to SqlPackage.exe"

    if (-not (Test-Path $sqlPackagePath)) {
        Write-Host "  ERROR: File not found at '$sqlPackagePath'." -ForegroundColor Red
        exit 1
    }
}

# ── Step 2: SQL Server Connection Details ────────────────────────────────────
Write-Host ""
Write-Host "  Step 2: SQL Server connection details" -ForegroundColor Yellow
Write-Host ""

$serverName = Read-Host "  SQL Server hostname or instance (e.g. myserver\SQLEXPRESS or myserver,1433)"

Write-Host ""
Write-Host "  Authentication method:" -ForegroundColor Yellow
Write-Host "  [1] SQL Server Authentication (username + password)" -ForegroundColor White
Write-Host "  [2] Windows Authentication (current user)" -ForegroundColor White
Write-Host ""
$authChoice = Read-Host "  Selection"

$useSqlAuth = $false
$username = ""
$password = $null

switch ($authChoice) {
    "1" {
        $useSqlAuth = $true
        Write-Host ""
        $username = Read-Host "  SQL Server username"
        $password = Read-Host "  SQL Server password" -AsSecureString
    }
    "2" {
        $useSqlAuth = $false
        Write-Host "  Using Windows Authentication with current user." -ForegroundColor Green
    }
    default {
        Write-Host "  Invalid selection. Defaulting to SQL Server Authentication." -ForegroundColor Yellow
        $useSqlAuth = $true
        Write-Host ""
        $username = Read-Host "  SQL Server username"
        $password = Read-Host "  SQL Server password" -AsSecureString
    }
}

# ── Step 3: Enumerate and Select Database ────────────────────────────────────
Write-Host ""
Write-Host "  Step 3: Discovering databases on '$serverName'..." -ForegroundColor Yellow
Write-Host ""

# Build connection string for querying databases
if ($useSqlAuth) {
    $plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    )
    $connString = "Server=$serverName;User Id=$username;Password=$plainPwd;Encrypt=Optional;TrustServerCertificate=True;Connection Timeout=15;"
}
else {
    $connString = "Server=$serverName;Integrated Security=True;Encrypt=Optional;TrustServerCertificate=True;Connection Timeout=15;"
}

# Query for databases
try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    $conn.Open()

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state_desc = 'ONLINE'
  AND name NOT IN ('ReportServer', 'ReportServerTempDB', 'SSISDB', 'distribution')
ORDER BY name
"@

    $reader = $cmd.ExecuteReader()
    $databases = @()
    while ($reader.Read()) {
        $databases += $reader["name"]
    }
    $reader.Close()
    $conn.Close()
}
catch {
    Write-Host "  ERROR: Could not connect to SQL Server." -ForegroundColor Red
    Write-Host "  Details: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please verify:" -ForegroundColor Yellow
    Write-Host "    - The server name/instance is correct" -ForegroundColor DarkGray
    Write-Host "    - The server is reachable from this machine" -ForegroundColor DarkGray
    Write-Host "    - The credentials are correct" -ForegroundColor DarkGray
    Write-Host "    - SQL Server is running and accepting connections" -ForegroundColor DarkGray

    # Clean up password from memory
    if ($plainPwd) { $plainPwd = $null }
    [System.GC]::Collect()
    exit 1
}

if ($databases.Count -eq 0) {
    Write-Host "  No user databases found on '$serverName'." -ForegroundColor Red
    if ($plainPwd) { $plainPwd = $null }
    [System.GC]::Collect()
    exit 1
}

Write-Host "  Found $($databases.Count) database(s):" -ForegroundColor Green
Write-Host ""

for ($i = 0; $i -lt $databases.Count; $i++) {
    Write-Host "  [$($i + 1)] $($databases[$i])" -ForegroundColor White
}

Write-Host ""
$dbChoice = Read-Host "  Select database number"
$dbIndex = [int]$dbChoice - 1

if ($dbIndex -lt 0 -or $dbIndex -ge $databases.Count) {
    Write-Host "  Invalid selection." -ForegroundColor Red
    if ($plainPwd) { $plainPwd = $null }
    [System.GC]::Collect()
    exit 1
}

$selectedDb = $databases[$dbIndex]
Write-Host ""
Write-Host "  Selected: $selectedDb" -ForegroundColor Green

# ── Step 4: Configure Output ─────────────────────────────────────────────────
Write-Host ""
Write-Host "  Step 4: Output configuration" -ForegroundColor Yellow
Write-Host ""

if (-not $OutputDir) {
    $defaultDir = Join-Path (Get-Location) "exports"
    $OutputDir = Read-Host "  Output directory (Enter for '$defaultDir')"
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $OutputDir = $defaultDir
    }
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Host "  Created output directory: $OutputDir" -ForegroundColor DarkGray
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dacpacFile = Join-Path $OutputDir "$selectedDb`_$timestamp.dacpac"

# ── Step 5: Extract ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host "  Extracting '$selectedDb' to:" -ForegroundColor Cyan
Write-Host "  $dacpacFile" -ForegroundColor White
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""

# Build SqlPackage arguments
$spArgs = @(
    "/Action:Extract",
    "/TargetFile:`"$dacpacFile`"",
    "/SourceServerName:`"$serverName`"",
    "/SourceDatabaseName:`"$selectedDb`""
)

if ($useSqlAuth) {
    $spArgs += "/SourceUser:`"$username`""
    $spArgs += "/SourcePassword:`"$plainPwd`""
}
else {
    # No extra args needed — SqlPackage uses Windows auth by default
}

$spArgs += "/SourceEncryptConnection:Optional"
$spArgs += "/SourceTrustServerCertificate:True"
$spArgs += "/p:VerifyExtraction=True"

Write-Host "  Running SqlPackage..." -ForegroundColor Yellow
Write-Host ""

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $process = Start-Process -FilePath $sqlPackagePath -ArgumentList $spArgs `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$OutputDir\sqlpackage-stdout.log" `
        -RedirectStandardError "$OutputDir\sqlpackage-stderr.log"

    $stopwatch.Stop()
    $elapsed = $stopwatch.Elapsed.ToString("mm\:ss")

    # Display output
    $stdout = Get-Content "$OutputDir\sqlpackage-stdout.log" -ErrorAction SilentlyContinue
    if ($stdout) {
        $stdout | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }

    if ($process.ExitCode -eq 0) {
        $fileSize = (Get-Item $dacpacFile).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 2)

        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                  EXTRACTION COMPLETE                        ║" -ForegroundColor Green
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Database:  $selectedDb" -ForegroundColor White
        Write-Host "  Server:    $serverName" -ForegroundColor White
        Write-Host "  Output:    $dacpacFile" -ForegroundColor White
        Write-Host "  Size:      $fileSizeMB MB" -ForegroundColor White
        Write-Host "  Duration:  $elapsed" -ForegroundColor White
        Write-Host ""
    }
    else {
        Write-Host ""
        Write-Host "  EXTRACTION FAILED (exit code: $($process.ExitCode))" -ForegroundColor Red
        Write-Host ""
        $stderr = Get-Content "$OutputDir\sqlpackage-stderr.log" -ErrorAction SilentlyContinue
        if ($stderr) {
            Write-Host "  Error output:" -ForegroundColor Red
            $stderr | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        }
        Write-Host ""
        Write-Host "  Full logs in: $OutputDir" -ForegroundColor DarkGray
    }
}
catch {
    $stopwatch.Stop()
    Write-Host "  ERROR: Failed to run SqlPackage.exe: $_" -ForegroundColor Red
}
finally {
    # Clean up temp log files on success
    Remove-Item "$OutputDir\sqlpackage-stdout.log" -ErrorAction SilentlyContinue
    Remove-Item "$OutputDir\sqlpackage-stderr.log" -ErrorAction SilentlyContinue
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
if ($plainPwd) { $plainPwd = $null }
$password = $null
$connString = $null
[System.GC]::Collect()
Write-Host "  Credentials cleared from memory." -ForegroundColor DarkGray
Write-Host ""
