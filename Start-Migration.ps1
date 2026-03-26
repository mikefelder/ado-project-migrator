#Requires -Version 5.1
<#
.SYNOPSIS
    ADO Project Migrator — Selectively migrate projects from Azure DevOps Server 2022
    (on-premises) to Azure DevOps Services (cloud).

.DESCRIPTION
    Interactive CLI tool that:
    1. Connects to a source ADO Server 2022 instance and one or more ADO Services orgs
    2. Discovers and displays source projects
    3. Lets the user select which projects to migrate
    4. Maps each project to a destination org/project (split, merge, or 1:1)
    5. Migrates Git repos, work items, areas/iterations, and pipeline definitions
    6. Produces a migration report

    Sensitive data (PATs) is held only in memory and never written to disk.

.EXAMPLE
    ./Start-Migration.ps1
    ./Start-Migration.ps1 -Verbose
#>
[CmdletBinding()]
param(
    [switch]$SkipRepoMigration,
    [switch]$SkipWorkItemMigration,
    [switch]$SkipPipelineMigration
)

$ErrorActionPreference = "Stop"

# ── Import modules ───────────────────────────────────────────────────────────
$modulePath = Join-Path $PSScriptRoot "modules"

Import-Module (Join-Path $modulePath "Logging.psm1")        -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "Connection.psm1")      -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "ProjectDiscovery.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "InteractiveUI.psm1")   -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "WorkItemMigration.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "RepoMigration.psm1")   -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "PipelineMigration.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $modulePath "MigrationEngine.psm1") -Force -DisableNameChecking

# ── Initialize ───────────────────────────────────────────────────────────────
$logFile = Initialize-MigrationLog
Show-Banner

Write-Host "  This tool will guide you through migrating projects from" -ForegroundColor White
Write-Host "  Azure DevOps Server 2022 (on-prem) to Azure DevOps Services (cloud)." -ForegroundColor White
Write-Host ""
Write-Host "  What you'll need:" -ForegroundColor Yellow
Write-Host "    1. The URL of your ADO Server 2022 instance" -ForegroundColor DarkGray
Write-Host "    2. A Personal Access Token (PAT) for the source server" -ForegroundColor DarkGray
Write-Host "    3. Organization name(s) for your ADO Services destination(s)" -ForegroundColor DarkGray
Write-Host "    4. A PAT for each destination organization" -ForegroundColor DarkGray
Write-Host "    5. Git installed and in PATH (for repo migration)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Security note: PATs are held in memory only and are never saved to disk." -ForegroundColor Green
Write-Host ""

$proceed = Read-Host "Press Enter to begin setup, or 'q' to quit"
if ($proceed -eq 'q') { exit 0 }

# ── Step 1: Source Connection ────────────────────────────────────────────────
Write-MigrationLog -Message "Step 1: Configuring source connection..." -Level "INFO"

$source = Initialize-SourceConnection
if (-not $source) {
    Write-MigrationLog -Message "Could not connect to source server. Exiting." -Level "ERROR"
    exit 1
}

# ── Step 2: Destination Connection(s) ────────────────────────────────────────
Write-MigrationLog -Message "Step 2: Configuring destination connection(s)..." -Level "INFO"

$destinations = Initialize-DestinationConnections
if (-not $destinations) {
    Write-MigrationLog -Message "No destinations configured. Exiting." -Level "ERROR"
    exit 1
}

# ── Step 3: Discover Source Projects ─────────────────────────────────────────
Write-MigrationLog -Message "Step 3: Discovering source projects..." -Level "INFO"

$projects = Get-AdoProjects -BaseUrl $source.BaseUrl -AuthHeader $source.AuthHeader -ApiVersion $source.ApiVersion

if ($projects.Count -eq 0) {
    Write-MigrationLog -Message "No projects found on the source server." -Level "ERROR"
    exit 1
}

# Show project details
Write-Host ""
Write-Host "  Gathering project details (repos, work items, pipelines)..." -ForegroundColor Yellow

foreach ($proj in $projects) {
    $details = Get-AdoProjectDetails -BaseUrl $source.BaseUrl -AuthHeader $source.AuthHeader `
        -ProjectName $proj.name -ApiVersion $source.ApiVersion

    # Attach details for display
    $proj | Add-Member -NotePropertyName "_repos" -NotePropertyValue $details.Repositories.Count -Force
    $proj | Add-Member -NotePropertyName "_workItems" -NotePropertyValue $details.WorkItemCount -Force
    $proj | Add-Member -NotePropertyName "_pipelines" -NotePropertyValue $details.BuildDefinitions.Count -Force

    Write-Host "    $($proj.name): $($details.Repositories.Count) repos, $($details.WorkItemCount) work items, $($details.BuildDefinitions.Count) pipelines" -ForegroundColor DarkGray
}

# ── Step 4: Interactive Project Selection ────────────────────────────────────
Write-MigrationLog -Message "Step 4: Select projects to migrate..." -Level "INFO"

$selectedProjects = Select-SourceProjects -Projects $projects
if (-not $selectedProjects -or $selectedProjects.Count -eq 0) {
    Write-MigrationLog -Message "No projects selected. Exiting." -Level "WARN"
    exit 0
}

# ── Step 5: Build Migration Plan ────────────────────────────────────────────
Write-MigrationLog -Message "Step 5: Building migration plan..." -Level "INFO"

$migrationPlan = Build-MigrationPlan -SelectedProjects $selectedProjects -Destinations $destinations

if (-not $migrationPlan -or $migrationPlan.Count -eq 0) {
    Write-MigrationLog -Message "Empty migration plan. Exiting." -Level "WARN"
    exit 0
}

# ── Step 6: Confirm ─────────────────────────────────────────────────────────
$confirmed = Confirm-MigrationPlan -Plan $migrationPlan
if (-not $confirmed) {
    Write-MigrationLog -Message "Migration cancelled by user." -Level "WARN"
    exit 0
}

# ── Step 7: Execute Migration ───────────────────────────────────────────────
Write-MigrationLog -Message "Step 7: Starting migration..." -Level "INFO"
Write-Host ""

$results = @()

foreach ($entry in $migrationPlan) {
    $result = Start-ProjectMigration -Source $source -PlanEntry $entry
    $results += $result
}

# ── Step 8: Report ──────────────────────────────────────────────────────────
Write-MigrationLog -Message "Step 8: Generating migration report..." -Level "INFO"

$reportFile = Write-MigrationReport -MigrationResults $results

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                  MIGRATION COMPLETE                         ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Log file:    $logFile" -ForegroundColor DarkGray
Write-Host "  Report file: $reportFile" -ForegroundColor DarkGray
Write-Host ""

$succeeded = ($results | Where-Object { $_.Status -eq "Success" }).Count
$partial = ($results | Where-Object { $_.Status -eq "Partial" }).Count
$failed = ($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host "  Results: $succeeded succeeded, $partial partial, $failed failed" -ForegroundColor $(
    if ($failed -gt 0) { "Yellow" } else { "Green" }
)
Write-Host ""

# ── Cleanup: Clear sensitive data from memory ───────────────────────────────
Write-MigrationLog -Message "Clearing sensitive data from memory..." -Level "INFO"
$source = $null
$destinations = $null
$migrationPlan = $null
[System.GC]::Collect()

Write-Host "  Sensitive data cleared. Goodbye!" -ForegroundColor Green
