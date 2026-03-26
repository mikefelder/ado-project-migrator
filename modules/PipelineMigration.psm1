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
        [string]$DestProject
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

Export-ModuleMember -Function Copy-BuildDefinitions
