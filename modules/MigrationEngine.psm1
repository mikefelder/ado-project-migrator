#Requires -Version 5.1
<#
.SYNOPSIS
    Migration engine — orchestrates the full migration for each project in the plan.
#>

function Start-ProjectMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$PlanEntry,

        [hashtable]$IdentityMap,

        [switch]$DryRun
    )

    $sourceProject = $PlanEntry.SourceProject
    $destOrg = $PlanEntry.DestOrg
    $destProject = $PlanEntry.DestProjectName

    $result = @{
        SourceProject = $sourceProject
        DestOrg       = $destOrg.OrgName
        DestProject   = $destProject
        Status        = "Failed"
        Duration      = ""
        Details       = @{}
        Errors        = [System.Collections.ArrayList]::new()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-MigrationLog -Message "" -Level "INFO"
    Write-MigrationLog -Message "══════════════════════════════════════════════════════════════" -Level "INFO"
    $modeLabel = if ($DryRun) { " [DRY RUN]" } else { "" }
    Write-MigrationLog -Message "  Migrating$modeLabel`: $sourceProject  ──►  $($destOrg.OrgName)/$destProject" -Level "INFO"
    Write-MigrationLog -Message "══════════════════════════════════════════════════════════════" -Level "INFO"

    # Step 1: Ensure destination project exists
    if (-not $PlanEntry.MergeIntoExisting) {
        if ($DryRun) {
            Write-MigrationLog -Message "  [DRY RUN] Would create destination project '$destProject'." -Level "DEBUG"
        }
        else {
            Write-MigrationLog -Message "  Creating destination project '$destProject'..." -Level "INFO"
            try {
                # Check if project already exists
                $existingCheck = $null
                $checkUrl = "$($destOrg.BaseUrl)/_apis/projects/$([Uri]::EscapeDataString($destProject))?api-version=$($destOrg.ApiVersion)"
                try {
                    $existingCheck = Invoke-AdoApi -Url $checkUrl -AuthHeader $destOrg.AuthHeader
                }
                catch { }

                if ($existingCheck) {
                    Write-MigrationLog -Message "  Project '$destProject' already exists. Proceeding with migration into it." -Level "WARN"
                }
                else {
                    # Determine process template from source
                    $srcEncoded = [Uri]::EscapeDataString($sourceProject)
                    $srcProjUrl = "$($Source.BaseUrl)/_apis/projects/$srcEncoded`?includeCapabilities=true&api-version=$($Source.ApiVersion)"
                    $srcProjDetails = Invoke-AdoApi -Url $srcProjUrl -AuthHeader $Source.AuthHeader

                    $processName = "Agile" # Default fallback
                    if ($srcProjDetails.capabilities.processTemplate.templateName) {
                        $processName = $srcProjDetails.capabilities.processTemplate.templateName
                    }

                    $created = New-AdoProject -BaseUrl $destOrg.BaseUrl -AuthHeader $destOrg.AuthHeader `
                        -ProjectName $destProject -Description "Migrated from $sourceProject" `
                        -ProcessTemplate $processName -ApiVersion $destOrg.ApiVersion

                    if (-not $created) {
                        $result.Errors.Add("Failed to create destination project.") | Out-Null
                        $stopwatch.Stop()
                        $result.Duration = $stopwatch.Elapsed.ToString("hh\:mm\:ss")
                        return $result
                    }
                }
            }
            catch {
                $result.Errors.Add("Project creation error: $_") | Out-Null
                $stopwatch.Stop()
                $result.Duration = $stopwatch.Elapsed.ToString("hh\:mm\:ss")
                return $result
            }
        }
    }

    $destConn = @{
        BaseUrl    = $destOrg.BaseUrl
        AuthHeader = $destOrg.AuthHeader
        Pat        = $destOrg.Pat
        ApiVersion = $destOrg.ApiVersion
    }

    $anySuccess = $false
    $anyFailure = $false

    # Step 2: Process validation (pre-flight)
    if ($PlanEntry.MigrateWorkItems -and -not $DryRun) {
        try {
            Write-MigrationLog -Message "  Running process template compatibility check..." -Level "INFO"
            $validation = Test-ProcessCompatibility -Source $Source -Destination $destConn `
                -SourceProject $sourceProject -DestProject $destProject
            Show-ValidationReport -ValidationResult $validation
            if (-not $validation.Valid) {
                Write-MigrationLog -Message "  Process validation found issues. Work item migration may have failures." -Level "WARN"
            }
            $result.Details["ProcessValidation"] = if ($validation.Valid) { "Passed" } else { "$($validation.Issues.Count) issue(s)" }
        }
        catch {
            Write-MigrationLog -Message "  Process validation error (non-blocking): $_" -Level "WARN"
        }
    }

    # Step 3: Migrate Work Items (areas, iterations, then items)
    if ($PlanEntry.MigrateWorkItems) {
        try {
            $areaCount = Copy-AreaTree -Source $Source -Destination $destConn -SourceProject $sourceProject -DestProject $destProject -DryRun:$DryRun
            $result.Details["AreaNodes"] = $areaCount

            $iterCount = Copy-IterationTree -Source $Source -Destination $destConn -SourceProject $sourceProject -DestProject $destProject -DryRun:$DryRun
            $result.Details["IterationNodes"] = $iterCount

            $wiParams = @{
                Source        = $Source
                Destination   = $destConn
                SourceProject = $sourceProject
                DestProject   = $destProject
                DryRun        = $DryRun
            }
            if ($IdentityMap) { $wiParams["IdentityMap"] = $IdentityMap }
            $wiResult = Copy-WorkItems @wiParams
            $result.Details["WorkItemsMigrated"] = $wiResult.Migrated
            $result.Details["WorkItemsFailed"] = $wiResult.Failed

            if ($wiResult.Migrated -gt 0) { $anySuccess = $true }
            if ($wiResult.Failed -gt 0) { $anyFailure = $true }
        }
        catch {
            Write-MigrationLog -Message "  Work item migration error: $_" -Level "ERROR"
            $result.Errors.Add("Work item migration: $_") | Out-Null
            $anyFailure = $true
        }
    }

    # Step 4: Migrate Git Repositories
    if ($PlanEntry.MigrateRepos) {
        try {
            $repoResult = Copy-GitRepositories -Source $Source -Destination $destConn -SourceProject $sourceProject -DestProject $destProject -DryRun:$DryRun
            $result.Details["ReposMigrated"] = $repoResult.Migrated
            $result.Details["ReposFailed"] = $repoResult.Failed

            if ($repoResult.Migrated -gt 0) { $anySuccess = $true }
            if ($repoResult.Failed -gt 0) { $anyFailure = $true }
        }
        catch {
            Write-MigrationLog -Message "  Repository migration error: $_" -Level "ERROR"
            $result.Errors.Add("Repo migration: $_") | Out-Null
            $anyFailure = $true
        }
    }

    # Step 5: Migrate Build/Pipeline Definitions
    if ($PlanEntry.MigratePipelines) {
        try {
            $pipeResult = Copy-BuildDefinitions -Source $Source -Destination $destConn -SourceProject $sourceProject -DestProject $destProject -DryRun:$DryRun
            $result.Details["PipelinesMigrated"] = $pipeResult.Migrated
            $result.Details["PipelinesSkipped"] = $pipeResult.Skipped
            $result.Details["PipelinesFailed"] = $pipeResult.Failed

            if ($pipeResult.Migrated -gt 0) { $anySuccess = $true }
            if ($pipeResult.Failed -gt 0) { $anyFailure = $true }
        }
        catch {
            Write-MigrationLog -Message "  Pipeline migration error: $_" -Level "ERROR"
            $result.Errors.Add("Pipeline migration: $_") | Out-Null
            $anyFailure = $true
        }
    }

    # Step 6: Migrate Release Pipelines
    if ($PlanEntry.MigrateReleases) {
        try {
            $relResult = Copy-ReleaseDefinitions -Source $Source -Destination $destConn `
                -SourceProject $sourceProject -DestProject $destProject -DryRun:$DryRun
            $result.Details["ReleasesMigrated"] = $relResult.Migrated
            $result.Details["ReleasesFailed"] = $relResult.Failed

            if ($relResult.Migrated -gt 0) { $anySuccess = $true }
            if ($relResult.Failed -gt 0) { $anyFailure = $true }
        }
        catch {
            Write-MigrationLog -Message "  Release pipeline migration error: $_" -Level "ERROR"
            $result.Errors.Add("Release pipeline migration: $_") | Out-Null
            $anyFailure = $true
        }
    }

    # Step 7: Migrate Shared Queries
    if ($PlanEntry.MigrateQueries) {
        try {
            $queryResult = Copy-SharedQueries -Source $Source -Destination $destConn `
                -SourceProject $sourceProject -DestProject $destProject -DryRun:$DryRun
            $result.Details["QueriesMigrated"] = $queryResult.Migrated
            $result.Details["QueriesFailed"] = $queryResult.Failed

            if ($queryResult.Migrated -gt 0) { $anySuccess = $true }
            if ($queryResult.Failed -gt 0) { $anyFailure = $true }
        }
        catch {
            Write-MigrationLog -Message "  Shared query migration error: $_" -Level "ERROR"
            $result.Errors.Add("Query migration: $_") | Out-Null
            $anyFailure = $true
        }
    }

    # Determine overall status
    if ($anySuccess -and $anyFailure) {
        $result.Status = "Partial"
    }
    elseif ($anySuccess) {
        $result.Status = "Success"
    }
    else {
        $result.Status = "Failed"
    }

    $stopwatch.Stop()
    $result.Duration = $stopwatch.Elapsed.ToString("hh\:mm\:ss")

    Write-MigrationLog -Message "  Migration of '$sourceProject' completed: $($result.Status) ($($result.Duration))" -Level $(
        if ($result.Status -eq "Success") { "SUCCESS" }
        elseif ($result.Status -eq "Partial") { "WARN" }
        else { "ERROR" }
    )

    return $result
}

Export-ModuleMember -Function Start-ProjectMigration
