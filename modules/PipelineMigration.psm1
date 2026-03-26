#Requires -Version 5.1
<#
.SYNOPSIS
    Pipeline/build definition migration — export from source and import to destination.
#>

function Copy-BuildDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Destination,

        [Parameter(Mandatory)]
        [string]$SourceProject,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [switch]$DryRun
    )

    Write-MigrationLog -Message "  Migrating build/pipeline definitions..." -Level "INFO"

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    # Get source build definitions
    $srcUrl = "$($Source.BaseUrl)/$srcEncoded/_apis/build/definitions?api-version=$($Source.ApiVersion)"
    $srcDefs = (Invoke-AdoApi -Url $srcUrl -AuthHeader $Source.AuthHeader).value

    if ($srcDefs.Count -eq 0) {
        Write-MigrationLog -Message "  No build definitions found." -Level "INFO"
        return @{ Migrated = 0; Failed = 0; Skipped = 0 }
    }

    Write-MigrationLog -Message "  Found $($srcDefs.Count) build definition(s)." -Level "INFO"

    if ($DryRun) {
        Write-MigrationLog -Message "  [DRY RUN] Would migrate $($srcDefs.Count) build definition(s)." -Level "DEBUG"
        return @{ Migrated = $srcDefs.Count; Failed = 0; Skipped = 0 }
    }

    # Get destination repos for mapping
    $dstRepoUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/git/repositories?api-version=$($Destination.ApiVersion)"
    $dstRepos = (Invoke-AdoApi -Url $dstRepoUrl -AuthHeader $Destination.AuthHeader).value
    $dstRepoMap = @{}
    foreach ($r in $dstRepos) { $dstRepoMap[$r.name] = $r }

    $migrated = 0
    $failed = 0
    $skipped = 0

    foreach ($defSummary in $srcDefs) {
        $defName = $defSummary.name

        try {
            # Get full definition
            $fullUrl = "$($Source.BaseUrl)/$srcEncoded/_apis/build/definitions/$($defSummary.id)?api-version=$($Source.ApiVersion)"
            $fullDef = Invoke-AdoApi -Url $fullUrl -AuthHeader $Source.AuthHeader

            # YAML pipelines — export as reference only
            if ($fullDef.process -and $fullDef.process.type -eq 2) {
                # Type 2 = YAML pipeline. These live in the repo, so they migrate with the repo.
                Write-MigrationLog -Message "    '$defName': YAML pipeline (migrates with repo, creating definition reference)." -Level "INFO"

                $yamlDef = Build-YamlPipelineDefinition -SourceDef $fullDef -DestProject $DestProject `
                    -DstRepoMap $dstRepoMap -Destination $Destination

                if ($yamlDef) {
                    $createUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/build/definitions?api-version=$($Destination.ApiVersion)"
                    Invoke-AdoApi -Url $createUrl -AuthHeader $Destination.AuthHeader -Method "Post" -Body $yamlDef | Out-Null
                    Write-MigrationLog -Message "    '$defName': Created YAML pipeline definition." -Level "SUCCESS"
                    $migrated++
                }
                else {
                    Write-MigrationLog -Message "    '$defName': Skipped — repo not found in destination." -Level "WARN"
                    $skipped++
                }
                continue
            }

            # Classic pipelines — recreate the definition
            if ($fullDef.process -and $fullDef.process.type -eq 1) {
                Write-MigrationLog -Message "    '$defName': Classic pipeline — exporting definition." -Level "INFO"

                $classicDef = Build-ClassicPipelineDefinition -SourceDef $fullDef -DestProject $DestProject `
                    -DstRepoMap $dstRepoMap -Destination $Destination

                if ($classicDef) {
                    $createUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/build/definitions?api-version=$($Destination.ApiVersion)"
                    Invoke-AdoApi -Url $createUrl -AuthHeader $Destination.AuthHeader -Method "Post" -Body $classicDef | Out-Null
                    Write-MigrationLog -Message "    '$defName': Created classic pipeline definition." -Level "SUCCESS"
                    $migrated++
                }
                else {
                    $skipped++
                }
                continue
            }

            Write-MigrationLog -Message "    '$defName': Unknown pipeline type ($($fullDef.process.type)) — skipped." -Level "WARN"
            $skipped++
        }
        catch {
            Write-MigrationLog -Message "    Failed to migrate pipeline '$defName': $_" -Level "ERROR"
            $failed++
        }
    }

    Write-MigrationLog -Message "  Pipelines: $migrated migrated, $skipped skipped, $failed failed." -Level "SUCCESS"
    return @{ Migrated = $migrated; Failed = $failed; Skipped = $skipped }
}

function Build-YamlPipelineDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SourceDef,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [Parameter(Mandatory)]
        [hashtable]$DstRepoMap,

        [Parameter(Mandatory)]
        [hashtable]$Destination
    )

    $repoName = $SourceDef.repository.name
    $destRepo = $DstRepoMap[$repoName]

    if (-not $destRepo) {
        return $null
    }

    $dstProjectId = Get-DestProjectIdForPipeline -Destination $Destination -ProjectName $DestProject

    return @{
        name       = $SourceDef.name
        type       = "build"
        quality    = "definition"
        project    = @{ id = $dstProjectId }
        repository = @{
            id            = $destRepo.id
            name          = $destRepo.name
            type          = "TfsGit"
            defaultBranch = $SourceDef.repository.defaultBranch
        }
        process    = @{
            type       = 2
            yamlFilename = $SourceDef.process.yamlFilename
        }
        queue      = @{
            name = "Azure Pipelines"
        }
    }
}

function Build-ClassicPipelineDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SourceDef,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [Parameter(Mandatory)]
        [hashtable]$DstRepoMap,

        [Parameter(Mandatory)]
        [hashtable]$Destination
    )

    $repoName = $SourceDef.repository.name
    $destRepo = $DstRepoMap[$repoName]

    if (-not $destRepo) {
        Write-MigrationLog -Message "      Repo '$repoName' not found in destination for classic pipeline." -Level "WARN"
        return $null
    }

    $dstProjectId = Get-DestProjectIdForPipeline -Destination $Destination -ProjectName $DestProject

    # Build a minimal classic definition; task details may need manual adjustment
    return @{
        name       = $SourceDef.name
        type       = "build"
        quality    = "definition"
        project    = @{ id = $dstProjectId }
        repository = @{
            id            = $destRepo.id
            name          = $destRepo.name
            type          = "TfsGit"
            defaultBranch = $SourceDef.repository.defaultBranch
        }
        process    = $SourceDef.process
        queue      = @{
            name = "Azure Pipelines"
        }
        variables  = $SourceDef.variables
        triggers   = $SourceDef.triggers
    }
}

function Get-DestProjectIdForPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Destination,

        [Parameter(Mandatory)]
        [string]$ProjectName
    )

    $encoded = [Uri]::EscapeDataString($ProjectName)
    $url = "$($Destination.BaseUrl)/_apis/projects/$encoded`?api-version=$($Destination.ApiVersion)"
    $project = Invoke-AdoApi -Url $url -AuthHeader $Destination.AuthHeader
    return $project.id
}

function Copy-ReleaseDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Destination,

        [Parameter(Mandatory)]
        [string]$SourceProject,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [switch]$DryRun
    )

    Write-MigrationLog -Message "  Migrating release definitions..." -Level "INFO"

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    # Release Management uses vsrm subdomain for ADO Services, but same base for on-prem
    $srcRmBase = Get-RmBaseUrl -BaseUrl $Source.BaseUrl
    $dstRmBase = Get-RmBaseUrl -BaseUrl $Destination.BaseUrl

    # Get source release definitions
    $srcUrl = "$srcRmBase/$srcEncoded/_apis/release/definitions?api-version=$($Source.ApiVersion)"
    $srcDefs = @()
    try {
        $srcDefs = (Invoke-AdoApi -Url $srcUrl -AuthHeader $Source.AuthHeader).value
    }
    catch {
        Write-MigrationLog -Message "  Could not retrieve release definitions (API may not be available): $_" -Level "WARN"
        return @{ Migrated = 0; Failed = 0; Skipped = 0 }
    }

    if ($srcDefs.Count -eq 0) {
        Write-MigrationLog -Message "  No release definitions found." -Level "INFO"
        return @{ Migrated = 0; Failed = 0; Skipped = 0 }
    }

    Write-MigrationLog -Message "  Found $($srcDefs.Count) release definition(s)." -Level "INFO"

    $migrated = 0
    $failed = 0
    $skipped = 0

    foreach ($defSummary in $srcDefs) {
        $defName = $defSummary.name

        try {
            # Get full definition
            $fullUrl = "$srcRmBase/$srcEncoded/_apis/release/definitions/$($defSummary.id)?api-version=$($Source.ApiVersion)"
            $fullDef = Invoke-AdoApi -Url $fullUrl -AuthHeader $Source.AuthHeader

            if ($DryRun) {
                Write-MigrationLog -Message "    [DRY RUN] Would migrate release definition: '$defName' ($($fullDef.environments.Count) environment(s))" -Level "DEBUG"
                $migrated++
                continue
            }

            # Build the new definition
            $newDef = Build-ReleaseDefinition -SourceDef $fullDef -SourceProject $SourceProject `
                -DestProject $DestProject -Destination $Destination

            if ($newDef) {
                $createUrl = "$dstRmBase/$dstEncoded/_apis/release/definitions?api-version=$($Destination.ApiVersion)"
                Invoke-AdoApi -Url $createUrl -AuthHeader $Destination.AuthHeader -Method "Post" -Body $newDef | Out-Null
                Write-MigrationLog -Message "    '$defName': Created release definition." -Level "SUCCESS"
                $migrated++
            }
            else {
                Write-MigrationLog -Message "    '$defName': Skipped — could not build definition." -Level "WARN"
                $skipped++
            }
        }
        catch {
            Write-MigrationLog -Message "    Failed to migrate release definition '$defName': $_" -Level "ERROR"
            $failed++
        }
    }

    Write-MigrationLog -Message "  Release definitions: $migrated migrated, $skipped skipped, $failed failed." -Level "SUCCESS"
    return @{ Migrated = $migrated; Failed = $failed; Skipped = $skipped }
}

function Get-RmBaseUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl
    )

    # ADO Services: https://dev.azure.com/org → https://vsrm.dev.azure.com/org
    # ADO Server on-prem: same base URL (RM is part of the same server)
    if ($BaseUrl -match "^https://dev\.azure\.com/") {
        return $BaseUrl -replace "^https://dev\.azure\.com/", "https://vsrm.dev.azure.com/"
    }
    return $BaseUrl
}

function Build-ReleaseDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SourceDef,

        [Parameter(Mandatory)]
        [string]$SourceProject,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [Parameter(Mandatory)]
        [hashtable]$Destination
    )

    $dstProjectId = Get-DestProjectIdForPipeline -Destination $Destination -ProjectName $DestProject

    # Clean up environments — remove IDs and approval identities that won't exist
    $environments = @()
    $rank = 1
    foreach ($env in $SourceDef.environments) {
        $cleanEnv = @{
            name                = $env.name
            rank                = $rank
            deployPhases        = $env.deployPhases
            retentionPolicy     = $env.retentionPolicy
            preDeployApprovals  = @{ approvals = @(@{ isAutomated = $true; rank = 1 }) }
            postDeployApprovals = @{ approvals = @(@{ isAutomated = $true; rank = 1 }) }
            conditions          = @()
        }

        # Add trigger condition for environments after the first
        if ($rank -gt 1) {
            $cleanEnv.conditions = @(@{
                conditionType = "environmentState"
                name          = $environments[-1].name
                value         = "4" # succeeded
            })
        }
        else {
            $cleanEnv.conditions = @(@{
                conditionType = "event"
                name          = "ReleaseStarted"
                value         = ""
            })
        }

        $environments += $cleanEnv
        $rank++
    }

    # Rewrite artifacts — map to destination build definitions by name
    $artifacts = @()
    foreach ($artifact in $SourceDef.artifacts) {
        if ($artifact.type -eq "Build") {
            # Try to find matching build def in destination
            $dstEncoded = [Uri]::EscapeDataString($DestProject)
            try {
                $dstBuildDefs = (Invoke-AdoApi -Url "$($Destination.BaseUrl)/$dstEncoded/_apis/build/definitions?api-version=$($Destination.ApiVersion)" -AuthHeader $Destination.AuthHeader).value
                $matchingDef = $dstBuildDefs | Where-Object { $_.name -eq $artifact.definitionReference.definition.name } | Select-Object -First 1
                if ($matchingDef) {
                    $artifacts += @{
                        alias               = $artifact.alias
                        type                = "Build"
                        definitionReference = @{
                            project    = @{ id = $dstProjectId; name = $DestProject }
                            definition = @{ id = "$($matchingDef.id)"; name = $matchingDef.name }
                        }
                        isPrimary           = $artifact.isPrimary
                    }
                }
                else {
                    Write-MigrationLog -Message "      Could not find matching build def for artifact '$($artifact.alias)'" -Level "WARN"
                }
            }
            catch {
                Write-MigrationLog -Message "      Error mapping artifact '$($artifact.alias)': $_" -Level "WARN"
            }
        }
    }

    return @{
        name         = $SourceDef.name
        description  = "$($SourceDef.description) [Migrated from $SourceProject]"
        environments = $environments
        artifacts    = $artifacts
        variables    = $SourceDef.variables
        triggers     = @()
    }
}

Export-ModuleMember -Function Copy-BuildDefinitions, Copy-ReleaseDefinitions
