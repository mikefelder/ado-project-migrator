#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive console UI for project selection and destination mapping.
#>

function Show-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          ADO PROJECT MIGRATOR                               ║" -ForegroundColor Cyan
    Write-Host "║          Azure DevOps Server 2022  ──►  ADO Services        ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string[]]$Options,

        [switch]$MultiSelect,

        [switch]$AllowBack
    )

    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host "  $('-' * $Title.Length)" -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])" -ForegroundColor White
    }

    if ($AllowBack) {
        Write-Host "  [B] Back" -ForegroundColor DarkGray
    }

    Write-Host ""

    if ($MultiSelect) {
        Write-Host "  Enter numbers separated by commas (e.g., 1,3,5) or 'all':" -ForegroundColor DarkGray
        $input_val = Read-Host -Prompt "  Selection"

        if ($input_val -eq 'B' -or $input_val -eq 'b') { return @(-1) }
        if ($input_val -eq 'all') { return @(0..($Options.Count - 1)) }

        $indices = @()
        foreach ($part in ($input_val -split ',')) {
            $num = $part.Trim()
            if ($num -match '^\d+$') {
                $idx = [int]$num - 1
                if ($idx -ge 0 -and $idx -lt $Options.Count) {
                    $indices += $idx
                }
            }
            # Support ranges like 1-5
            elseif ($num -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1] - 1
                $end = [int]$Matches[2] - 1
                for ($r = $start; $r -le $end -and $r -lt $Options.Count; $r++) {
                    if ($r -ge 0) { $indices += $r }
                }
            }
        }
        return ($indices | Sort-Object -Unique)
    }
    else {
        $input_val = Read-Host -Prompt "  Selection"
        if ($input_val -eq 'B' -or $input_val -eq 'b') { return -1 }
        $idx = [int]$input_val - 1
        if ($idx -ge 0 -and $idx -lt $Options.Count) { return $idx }
        Write-Host "  Invalid selection." -ForegroundColor Red
        return -2
    }
}

function Select-SourceProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Projects
    )

    $options = $Projects | ForEach-Object {
        "$($_.name) ($(if ($_.description) { $_.description.Substring(0, [Math]::Min(50, $_.description.Length)) } else { 'No description' }))"
    }

    Write-Host ""
    Write-Host "  Found $($Projects.Count) project(s) on source server:" -ForegroundColor Green

    $selected = Show-Menu -Title "Select projects to migrate" -Options $options -MultiSelect
    if ($selected -contains -1) { return $null }

    $selectedProjects = $selected | ForEach-Object { $Projects[$_] }

    Write-Host ""
    Write-Host "  Selected $($selectedProjects.Count) project(s):" -ForegroundColor Green
    foreach ($p in $selectedProjects) {
        Write-Host "    • $($p.name)" -ForegroundColor White
    }

    return $selectedProjects
}

function Build-MigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$SelectedProjects,

        [Parameter(Mandatory)]
        [array]$Destinations
    )

    $plan = @()

    foreach ($project in $SelectedProjects) {
        Write-Host ""
        Write-Host "═" * 60 -ForegroundColor DarkCyan
        Write-Host "  Configuring migration for: $($project.name)" -ForegroundColor Cyan
        Write-Host "═" * 60 -ForegroundColor DarkCyan

        # Select destination org
        $orgOptions = $Destinations | ForEach-Object { "$($_.OrgName) ($($_.BaseUrl))" }
        $destIdx = Show-Menu -Title "Select destination organization for '$($project.name)'" -Options $orgOptions
        while ($destIdx -lt 0) {
            $destIdx = Show-Menu -Title "Select destination organization for '$($project.name)'" -Options $orgOptions
        }
        $destOrg = $Destinations[$destIdx]

        # Choose destination project name
        Write-Host ""
        Write-Host "  Destination project options:" -ForegroundColor Yellow
        Write-Host "  [1] Use same name: '$($project.name)'" -ForegroundColor White
        Write-Host "  [2] Merge into an existing project" -ForegroundColor White
        Write-Host "  [3] Specify a new project name" -ForegroundColor White
        Write-Host ""
        $nameChoice = Read-Host -Prompt "  Selection"

        $destProjectName = $project.name
        $mergeIntoExisting = $false

        switch ($nameChoice) {
            "1" {
                $destProjectName = $project.name
            }
            "2" {
                Write-Host "  Fetching existing projects from '$($destOrg.OrgName)'..." -ForegroundColor Yellow
                $existingProjects = Get-AdoProjects -BaseUrl $destOrg.BaseUrl -AuthHeader $destOrg.AuthHeader -ApiVersion $destOrg.ApiVersion

                if ($existingProjects.Count -eq 0) {
                    Write-Host "  No existing projects found. Using same name." -ForegroundColor Yellow
                    $destProjectName = $project.name
                }
                else {
                    $existingOptions = $existingProjects | ForEach-Object { $_.name }
                    $existIdx = Show-Menu -Title "Select existing project to merge into" -Options $existingOptions
                    if ($existIdx -ge 0) {
                        $destProjectName = $existingProjects[$existIdx].name
                        $mergeIntoExisting = $true
                    }
                }
            }
            "3" {
                $destProjectName = Read-Host -Prompt "  New project name"
            }
        }

        # Select what to migrate
        $componentOptions = @(
            "Git Repositories (with full history)",
            "Work Items (areas, iterations, items, links, attachments)",
            "Build/Pipeline Definitions",
            "Release Pipelines (classic)",
            "Shared Queries",
            "All of the above"
        )
        $componentSelection = Show-Menu -Title "What should be migrated for '$($project.name)'?" -Options $componentOptions -MultiSelect

        $migrateRepos = $false
        $migrateWorkItems = $false
        $migratePipelines = $false
        $migrateReleases = $false
        $migrateQueries = $false

        if ($componentSelection -contains 5) {
            $migrateRepos = $true
            $migrateWorkItems = $true
            $migratePipelines = $true
            $migrateReleases = $true
            $migrateQueries = $true
        }
        else {
            $migrateRepos = $componentSelection -contains 0
            $migrateWorkItems = $componentSelection -contains 1
            $migratePipelines = $componentSelection -contains 2
            $migrateReleases = $componentSelection -contains 3
            $migrateQueries = $componentSelection -contains 4
        }

        $plan += @{
            SourceProject     = $project.name
            SourceProjectId   = $project.id
            DestOrg           = $destOrg
            DestProjectName   = $destProjectName
            MergeIntoExisting = $mergeIntoExisting
            MigrateRepos      = $migrateRepos
            MigrateWorkItems  = $migrateWorkItems
            MigratePipelines  = $migratePipelines
            MigrateReleases   = $migrateReleases
            MigrateQueries    = $migrateQueries
        }
    }

    return $plan
}

function Confirm-MigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Plan
    )

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║                  MIGRATION PLAN SUMMARY                     ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    foreach ($entry in $Plan) {
        $components = @()
        if ($entry.MigrateRepos) { $components += "Repos" }
        if ($entry.MigrateWorkItems) { $components += "Work Items" }
        if ($entry.MigratePipelines) { $components += "Pipelines" }
        if ($entry.MigrateReleases) { $components += "Releases" }
        if ($entry.MigrateQueries) { $components += "Queries" }

        $action = if ($entry.MergeIntoExisting) { "MERGE INTO" } else { "CREATE/MIGRATE TO" }

        Write-Host "  $($entry.SourceProject)" -ForegroundColor White -NoNewline
        Write-Host "  ──►  " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($entry.DestOrg.OrgName)/$($entry.DestProjectName)" -ForegroundColor Green
        Write-Host "    Action:     $action" -ForegroundColor DarkGray
        Write-Host "    Components: $($components -join ', ')" -ForegroundColor DarkGray
        Write-Host ""
    }

    Write-Host "  Are you sure you want to proceed with this migration?" -ForegroundColor Yellow
    Write-Host "  Type 'yes' to confirm, anything else to abort." -ForegroundColor DarkGray
    $confirm = Read-Host -Prompt "  Confirm"

    return ($confirm -eq 'yes')
}

Export-ModuleMember -Function Show-Banner, Show-Menu, Select-SourceProjects, Build-MigrationPlan, Confirm-MigrationPlan
