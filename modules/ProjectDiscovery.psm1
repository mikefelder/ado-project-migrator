#Requires -Version 5.1
<#
.SYNOPSIS
    Project discovery module — enumerates projects, repos, work items, pipelines from source.
#>

function Get-AdoProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$AuthHeader,

        [string]$ApiVersion = "7.1"
    )

    $url = "$BaseUrl/_apis/projects?`$top=500&api-version=$ApiVersion"
    $result = Invoke-AdoApi -Url $url -AuthHeader $AuthHeader
    return $result.value | Sort-Object name
}

function Get-AdoProjectDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$AuthHeader,

        [Parameter(Mandatory)]
        [string]$ProjectName,

        [string]$ApiVersion = "7.1"
    )

    $encodedProject = [Uri]::EscapeDataString($ProjectName)

    # Get repos
    $repoUrl = "$BaseUrl/$encodedProject/_apis/git/repositories?api-version=$ApiVersion"
    $repos = @()
    try {
        $repoResult = Invoke-AdoApi -Url $repoUrl -AuthHeader $AuthHeader
        $repos = $repoResult.value
    }
    catch {
        Write-MigrationLog -Message "  Could not retrieve repos for '$ProjectName': $_" -Level "WARN"
    }

    # Get work item count (using WIQL)
    $wiqlUrl = "$BaseUrl/$encodedProject/_apis/wit/wiql?api-version=$ApiVersion"
    $wiCount = 0
    try {
        $wiqlBody = @{ query = "SELECT [System.Id] FROM workitems WHERE [System.TeamProject] = '$ProjectName'" } | ConvertTo-Json
        $wiResult = Invoke-AdoApi -Url $wiqlUrl -AuthHeader $AuthHeader -Method "Post" -Body $wiqlBody
        $wiCount = $wiResult.workItems.Count
    }
    catch {
        Write-MigrationLog -Message "  Could not count work items for '$ProjectName': $_" -Level "WARN"
    }

    # Get build definitions
    $buildUrl = "$BaseUrl/$encodedProject/_apis/build/definitions?api-version=$ApiVersion"
    $builds = @()
    try {
        $buildResult = Invoke-AdoApi -Url $buildUrl -AuthHeader $AuthHeader
        $builds = $buildResult.value
    }
    catch {
        Write-MigrationLog -Message "  Could not retrieve build definitions for '$ProjectName': $_" -Level "WARN"
    }

    # Get teams
    $teamsUrl = "$BaseUrl/_apis/projects/$encodedProject/teams?api-version=$ApiVersion"
    $teams = @()
    try {
        $teamsResult = Invoke-AdoApi -Url $teamsUrl -AuthHeader $AuthHeader
        $teams = $teamsResult.value
    }
    catch {
        Write-MigrationLog -Message "  Could not retrieve teams for '$ProjectName': $_" -Level "WARN"
    }

    # Get areas
    $areasUrl = "$BaseUrl/$encodedProject/_apis/wit/classificationnodes/areas?`$depth=10&api-version=$ApiVersion"
    $areas = $null
    try {
        $areas = Invoke-AdoApi -Url $areasUrl -AuthHeader $AuthHeader
    }
    catch {
        Write-MigrationLog -Message "  Could not retrieve area paths for '$ProjectName': $_" -Level "WARN"
    }

    # Get iterations
    $iterUrl = "$BaseUrl/$encodedProject/_apis/wit/classificationnodes/iterations?`$depth=10&api-version=$ApiVersion"
    $iterations = $null
    try {
        $iterations = Invoke-AdoApi -Url $iterUrl -AuthHeader $AuthHeader
    }
    catch {
        Write-MigrationLog -Message "  Could not retrieve iteration paths for '$ProjectName': $_" -Level "WARN"
    }

    return @{
        ProjectName      = $ProjectName
        Repositories     = $repos
        WorkItemCount    = $wiCount
        BuildDefinitions = $builds
        Teams            = $teams
        AreaTree         = $areas
        IterationTree    = $iterations
    }
}

function Get-DestinationProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Destination
    )

    return Get-AdoProjects -BaseUrl $Destination.BaseUrl -AuthHeader $Destination.AuthHeader -ApiVersion $Destination.ApiVersion
}

function New-AdoProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$AuthHeader,

        [Parameter(Mandatory)]
        [string]$ProjectName,

        [string]$Description = "",

        [string]$ProcessTemplate = "Agile",

        [string]$ApiVersion = "7.1"
    )

    # Look up the process template ID
    $processUrl = "$BaseUrl/_apis/process/processes?api-version=$ApiVersion"
    $processes = Invoke-AdoApi -Url $processUrl -AuthHeader $AuthHeader
    $process = $processes.value | Where-Object { $_.name -eq $ProcessTemplate } | Select-Object -First 1

    if (-not $process) {
        throw "Process template '$ProcessTemplate' not found. Available: $(($processes.value | ForEach-Object { $_.name }) -join ', ')"
    }

    $body = @{
        name         = $ProjectName
        description  = $Description
        capabilities = @{
            versioncontrol  = @{ sourceControlType = "Git" }
            processTemplate = @{ templateTypeId = $process.id }
        }
    }

    $url = "$BaseUrl/_apis/projects?api-version=$ApiVersion"
    $result = Invoke-AdoApi -Url $url -AuthHeader $AuthHeader -Method "Post" -Body $body

    # Project creation is async — poll for completion
    if ($result.status -and $result.url) {
        Write-MigrationLog -Message "  Project creation queued. Waiting for completion..." -Level "INFO"
        $maxWait = 120
        $elapsed = 0
        while ($elapsed -lt $maxWait) {
            Start-Sleep -Seconds 5
            $elapsed += 5
            try {
                $status = Invoke-AdoApi -Url $result.url -AuthHeader $AuthHeader
                if ($status.status -eq "succeeded") {
                    Write-MigrationLog -Message "  Project '$ProjectName' created successfully." -Level "SUCCESS"
                    Start-Sleep -Seconds 3 # Allow APIs to catch up
                    return $true
                }
                elseif ($status.status -eq "failed") {
                    Write-MigrationLog -Message "  Project creation failed: $($status.detailedMessage)" -Level "ERROR"
                    return $false
                }
            }
            catch {
                # Polling endpoint may not be available yet
            }
        }
        Write-MigrationLog -Message "  Timed out waiting for project creation." -Level "ERROR"
        return $false
    }

    return $true
}

Export-ModuleMember -Function Get-AdoProjects, Get-AdoProjectDetails, Get-DestinationProjects, New-AdoProject
