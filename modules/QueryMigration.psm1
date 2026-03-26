#Requires -Version 5.1
<#
.SYNOPSIS
    Shared query migration — export query tree from source and recreate in destination.
#>

function Copy-SharedQueries {
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

    Write-MigrationLog -Message "  Migrating shared queries..." -Level "INFO"

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    # Get the full query tree from source (depth=2 gets Shared Queries and children)
    $url = "$($Source.BaseUrl)/$srcEncoded/_apis/wit/queries?`$depth=2&`$expand=all&api-version=$($Source.ApiVersion)"
    $queryTree = Invoke-AdoApi -Url $url -AuthHeader $Source.AuthHeader

    # Find the "Shared Queries" folder
    $sharedFolder = $queryTree.value | Where-Object { $_.isPublic -eq $true -and $_.isFolder -eq $true }

    if (-not $sharedFolder) {
        Write-MigrationLog -Message "  No shared queries found." -Level "INFO"
        return @{ Migrated = 0; Failed = 0 }
    }

    $migrated = 0
    $failed = 0

    foreach ($folder in $sharedFolder) {
        $childResult = Copy-QueryNode -Node $folder -Source $Source -Destination $Destination `
            -SourceProject $SourceProject -DestProject $DestProject `
            -ParentPath "Shared Queries" -DryRun:$DryRun
        $migrated += $childResult.Migrated
        $failed += $childResult.Failed
    }

    Write-MigrationLog -Message "  Shared queries: $migrated migrated, $failed failed." -Level "SUCCESS"
    return @{ Migrated = $migrated; Failed = $failed }
}

function Copy-QueryNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Node,

        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Destination,

        [Parameter(Mandatory)]
        [string]$SourceProject,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [string]$ParentPath = "Shared Queries",

        [switch]$DryRun
    )

    $migrated = 0
    $failed = 0
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    if (-not $Node.children) { return @{ Migrated = 0; Failed = 0 } }

    foreach ($child in $Node.children) {
        $childName = $child.name

        if ($child.isFolder) {
            # Create folder in destination
            if ($DryRun) {
                Write-MigrationLog -Message "    [DRY RUN] Would create query folder: $ParentPath/$childName" -Level "DEBUG"
                $migrated++
            }
            else {
                try {
                    $parentId = Get-QueryFolderId -BaseUrl $Destination.BaseUrl -AuthHeader $Destination.AuthHeader `
                        -Project $DestProject -FolderPath $ParentPath -ApiVersion $Destination.ApiVersion

                    $body = @{ name = $childName; isFolder = $true }
                    $createUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/wit/queries/$parentId`?api-version=$($Destination.ApiVersion)"
                    Invoke-AdoApi -Url $createUrl -AuthHeader $Destination.AuthHeader -Method "Post" -Body $body | Out-Null
                    Write-MigrationLog -Message "    Created query folder: $ParentPath/$childName" -Level "SUCCESS"
                    $migrated++
                }
                catch {
                    if ($_.Exception.Message -match "already exists") {
                        $migrated++
                    }
                    else {
                        Write-MigrationLog -Message "    Failed to create folder '$childName': $_" -Level "WARN"
                        $failed++
                    }
                }
            }

            # Recurse into subfolder — need full details
            $srcEncoded = [Uri]::EscapeDataString($SourceProject)
            try {
                $fullChild = Invoke-AdoApi -Url "$($Source.BaseUrl)/$srcEncoded/_apis/wit/queries/$($child.id)?`$depth=2&`$expand=all&api-version=$($Source.ApiVersion)" -AuthHeader $Source.AuthHeader
                $subResult = Copy-QueryNode -Node $fullChild -Source $Source -Destination $Destination `
                    -SourceProject $SourceProject -DestProject $DestProject `
                    -ParentPath "$ParentPath/$childName" -DryRun:$DryRun
                $migrated += $subResult.Migrated
                $failed += $subResult.Failed
            }
            catch {
                Write-MigrationLog -Message "    Could not recurse into folder '$childName': $_" -Level "WARN"
            }
        }
        else {
            # It's a query — rewrite the WIQL and create it
            $wiql = $child.wiql
            if ($wiql) {
                # Rewrite project references in the WIQL
                $newWiql = $wiql -replace [regex]::Escape($SourceProject), $DestProject
            }
            else {
                $newWiql = ""
            }

            if ($DryRun) {
                Write-MigrationLog -Message "    [DRY RUN] Would create query: $ParentPath/$childName" -Level "DEBUG"
                $migrated++
            }
            else {
                try {
                    $parentId = Get-QueryFolderId -BaseUrl $Destination.BaseUrl -AuthHeader $Destination.AuthHeader `
                        -Project $DestProject -FolderPath $ParentPath -ApiVersion $Destination.ApiVersion

                    $body = @{
                        name     = $childName
                        wiql     = $newWiql
                        isFolder = $false
                    }

                    # Include query type if available
                    if ($child.queryType) {
                        $body.queryType = $child.queryType
                    }

                    # Include columns if available
                    if ($child.columns) {
                        $body.columns = $child.columns
                    }

                    # Include sort columns if available
                    if ($child.sortColumns) {
                        $body.sortColumns = $child.sortColumns
                    }

                    $createUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/wit/queries/$parentId`?api-version=$($Destination.ApiVersion)"
                    Invoke-AdoApi -Url $createUrl -AuthHeader $Destination.AuthHeader -Method "Post" -Body $body | Out-Null
                    Write-MigrationLog -Message "    Created query: $ParentPath/$childName" -Level "SUCCESS"
                    $migrated++
                }
                catch {
                    if ($_.Exception.Message -match "already exists") {
                        $migrated++
                    }
                    else {
                        Write-MigrationLog -Message "    Failed to create query '$childName': $_" -Level "WARN"
                        $failed++
                    }
                }
            }
        }
    }

    return @{ Migrated = $migrated; Failed = $failed }
}

function Get-QueryFolderId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$AuthHeader,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$FolderPath,

        [string]$ApiVersion = "7.1"
    )

    $enc = [Uri]::EscapeDataString($Project)
    $pathEnc = [Uri]::EscapeDataString($FolderPath)
    $url = "$BaseUrl/$enc/_apis/wit/queries/$pathEnc`?api-version=$ApiVersion"

    try {
        $result = Invoke-AdoApi -Url $url -AuthHeader $AuthHeader
        return $result.id
    }
    catch {
        # Return "Shared Queries" as fallback
        $fallbackUrl = "$BaseUrl/$enc/_apis/wit/queries?`$depth=1&api-version=$ApiVersion"
        $tree = Invoke-AdoApi -Url $fallbackUrl -AuthHeader $AuthHeader
        $shared = $tree.value | Where-Object { $_.isPublic -eq $true -and $_.isFolder -eq $true } | Select-Object -First 1
        if ($shared) { return $shared.id }
        throw "Could not find query folder '$FolderPath'"
    }
}

Export-ModuleMember -Function Copy-SharedQueries
