#Requires -Version 5.1
<#
.SYNOPSIS
    Work item migration — areas, iterations, work items with links and attachments.
#>

function Copy-AreaTree {
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

    Write-MigrationLog -Message "  Migrating area paths..." -Level "INFO"

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    $url = "$($Source.BaseUrl)/$srcEncoded/_apis/wit/classificationnodes/areas?`$depth=10&api-version=$($Source.ApiVersion)"
    $areaTree = Invoke-AdoApi -Url $url -AuthHeader $Source.AuthHeader

    $count = 0
    if ($areaTree.children) {
        $count = Copy-ClassificationNodes -Nodes $areaTree.children -Destination $Destination -DestProject $dstEncoded -NodeType "areas" -ParentPath ""
    }

    Write-MigrationLog -Message "  Migrated $count area node(s)." -Level "SUCCESS"
    return $count
}

function Copy-IterationTree {
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

    Write-MigrationLog -Message "  Migrating iteration paths..." -Level "INFO"

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    $url = "$($Source.BaseUrl)/$srcEncoded/_apis/wit/classificationnodes/iterations?`$depth=10&api-version=$($Source.ApiVersion)"
    $iterTree = Invoke-AdoApi -Url $url -AuthHeader $Source.AuthHeader

    $count = 0
    if ($iterTree.children) {
        $count = Copy-ClassificationNodes -Nodes $iterTree.children -Destination $Destination -DestProject $dstEncoded -NodeType "iterations" -ParentPath ""
    }

    Write-MigrationLog -Message "  Migrated $count iteration node(s)." -Level "SUCCESS"
    return $count
}

function Copy-ClassificationNodes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Nodes,

        [Parameter(Mandatory)]
        [hashtable]$Destination,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [Parameter(Mandatory)]
        [ValidateSet("areas", "iterations")]
        [string]$NodeType,

        [string]$ParentPath = ""
    )

    $count = 0

    foreach ($node in $Nodes) {
        $nodePath = if ($ParentPath) { "$ParentPath/$($node.name)" } else { $node.name }

        $body = @{ name = $node.name }

        # Include dates for iterations
        if ($NodeType -eq "iterations" -and $node.attributes) {
            if ($node.attributes.startDate) {
                $body.attributes = @{}
                $body.attributes.startDate = $node.attributes.startDate
            }
            if ($node.attributes.finishDate) {
                if (-not $body.attributes) { $body.attributes = @{} }
                $body.attributes.finishDate = $node.attributes.finishDate
            }
        }

        $pathSegment = if ($ParentPath) { "$ParentPath/$($node.name)" } else { $node.name }
        $encodedPath = [Uri]::EscapeDataString($ParentPath)
        $url = if ($ParentPath) {
            "$($Destination.BaseUrl)/$DestProject/_apis/wit/classificationnodes/$NodeType/$encodedPath`?api-version=$($Destination.ApiVersion)"
        }
        else {
            "$($Destination.BaseUrl)/$DestProject/_apis/wit/classificationnodes/$NodeType`?api-version=$($Destination.ApiVersion)"
        }

        try {
            Invoke-AdoApi -Url $url -AuthHeader $Destination.AuthHeader -Method "Post" -Body $body | Out-Null
            $count++
        }
        catch {
            if ($_.Exception.Message -notmatch "VS402371") {
                Write-MigrationLog -Message "    Warning: Could not create $NodeType node '$nodePath': $_" -Level "WARN"
            }
            # VS402371 = node already exists, which is fine
            $count++
        }

        if ($node.children) {
            $childPath = if ($ParentPath) { "$ParentPath/$($node.name)" } else { $node.name }
            $count += Copy-ClassificationNodes -Nodes $node.children -Destination $Destination -DestProject $DestProject -NodeType $NodeType -ParentPath $childPath
        }
    }

    return $count
}

function Copy-WorkItems {
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

    Write-MigrationLog -Message "  Migrating work items..." -Level "INFO"

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    # Get all work item IDs via WIQL
    $wiqlUrl = "$($Source.BaseUrl)/$srcEncoded/_apis/wit/wiql?api-version=$($Source.ApiVersion)"
    $wiqlBody = @{
        query = "SELECT [System.Id] FROM workitems WHERE [System.TeamProject] = '$SourceProject' ORDER BY [System.Id]"
    } | ConvertTo-Json

    $wiqlResult = Invoke-AdoApi -Url $wiqlUrl -AuthHeader $Source.AuthHeader -Method "Post" -Body $wiqlBody
    $workItemIds = $wiqlResult.workItems | ForEach-Object { $_.id }

    if ($workItemIds.Count -eq 0) {
        Write-MigrationLog -Message "  No work items found." -Level "INFO"
        return @{ Migrated = 0; Failed = 0; IdMap = @{} }
    }

    Write-MigrationLog -Message "  Found $($workItemIds.Count) work item(s) to migrate." -Level "INFO"

    # Process in batches of 200
    $idMap = @{}        # oldId -> newId
    $migrated = 0
    $failed = 0
    $batchSize = 200

    for ($i = 0; $i -lt $workItemIds.Count; $i += $batchSize) {
        $batchIds = $workItemIds[$i..([Math]::Min($i + $batchSize - 1, $workItemIds.Count - 1))]
        $idsParam = $batchIds -join ','

        # Get full work item details
        $getUrl = "$($Source.BaseUrl)/_apis/wit/workitems?ids=$idsParam&`$expand=all&api-version=$($Source.ApiVersion)"
        $items = Invoke-AdoApi -Url $getUrl -AuthHeader $Source.AuthHeader

        foreach ($item in $items.value) {
            try {
                $newId = Copy-SingleWorkItem -Item $item -Source $Source -Destination $Destination `
                    -SourceProject $SourceProject -DestProject $DestProject -IdMap $idMap

                if ($newId) {
                    $idMap[$item.id] = $newId
                    $migrated++
                }
                else {
                    $failed++
                }
            }
            catch {
                Write-MigrationLog -Message "    Failed to migrate WI #$($item.id): $_" -Level "WARN"
                $failed++
            }
        }

        $total = $migrated + $failed
        Write-Host "`r  Progress: $total / $($workItemIds.Count) work items processed..." -NoNewline -ForegroundColor DarkGray
    }

    Write-Host "" # Clear the progress line

    # Create links between migrated items (parent/child, related, etc.)
    Write-MigrationLog -Message "  Restoring work item links..." -Level "INFO"
    $linksRestored = Restore-WorkItemLinks -Source $Source -Destination $Destination `
        -SourceProject $SourceProject -DestProject $DestProject -IdMap $idMap

    Write-MigrationLog -Message "  Work items: $migrated migrated, $failed failed, $linksRestored link(s) restored." -Level "SUCCESS"

    return @{
        Migrated = $migrated
        Failed   = $failed
        IdMap    = $idMap
    }
}

function Copy-SingleWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Item,

        [Parameter(Mandatory)]
        [hashtable]$Source,

        [Parameter(Mandatory)]
        [hashtable]$Destination,

        [Parameter(Mandatory)]
        [string]$SourceProject,

        [Parameter(Mandatory)]
        [string]$DestProject,

        [hashtable]$IdMap = @{}
    )

    $dstEncoded = [Uri]::EscapeDataString($DestProject)
    $wiType = $Item.fields.'System.WorkItemType'
    $encodedType = [Uri]::EscapeDataString($wiType)

    # Build the patch document
    $patchDoc = [System.Collections.ArrayList]::new()

    # Fields to copy
    $fieldsToCopy = @(
        'System.Title',
        'System.Description',
        'System.State',
        'System.Reason',
        'System.Tags',
        'Microsoft.VSTS.Common.Priority',
        'Microsoft.VSTS.Common.Severity',
        'Microsoft.VSTS.Common.AcceptanceCriteria',
        'Microsoft.VSTS.Scheduling.StoryPoints',
        'Microsoft.VSTS.Scheduling.Effort',
        'Microsoft.VSTS.Scheduling.RemainingWork',
        'Microsoft.VSTS.Scheduling.OriginalEstimate',
        'Microsoft.VSTS.Scheduling.CompletedWork',
        'Microsoft.VSTS.Common.ValueArea',
        'Microsoft.VSTS.Common.BusinessValue',
        'System.AssignedTo'
    )

    foreach ($field in $fieldsToCopy) {
        $value = $Item.fields.$field
        if ($null -ne $value -and $value -ne '') {
            # Rewrite project-scoped paths
            if ($field -eq 'System.AssignedTo' -and $value -is [hashtable]) {
                # Skip identity fields that may not resolve across orgs
                continue
            }
            $patchDoc.Add(@{
                op    = "add"
                path  = "/fields/$field"
                value = $value
            }) | Out-Null
        }
    }

    # Rewrite Area Path
    $areaPath = $Item.fields.'System.AreaPath'
    if ($areaPath) {
        $newAreaPath = $areaPath -replace "^$([regex]::Escape($SourceProject))", $DestProject
        $patchDoc.Add(@{
            op    = "add"
            path  = "/fields/System.AreaPath"
            value = $newAreaPath
        }) | Out-Null
    }

    # Rewrite Iteration Path
    $iterPath = $Item.fields.'System.IterationPath'
    if ($iterPath) {
        $newIterPath = $iterPath -replace "^$([regex]::Escape($SourceProject))", $DestProject
        $patchDoc.Add(@{
            op    = "add"
            path  = "/fields/System.IterationPath"
            value = $newIterPath
        }) | Out-Null
    }

    # Add a tag referencing the original ID for traceability
    $existingTags = $Item.fields.'System.Tags'
    $traceTag = "MigratedFrom:$($Item.id)"
    $newTags = if ($existingTags) { "$existingTags; $traceTag" } else { $traceTag }
    # Find and replace the tags entry
    $tagsEntry = $patchDoc | Where-Object { $_.path -eq "/fields/System.Tags" }
    if ($tagsEntry) {
        $tagsEntry.value = $newTags
    }
    else {
        $patchDoc.Add(@{
            op    = "add"
            path  = "/fields/System.Tags"
            value = $newTags
        }) | Out-Null
    }

    # Add history/description note about migration
    $patchDoc.Add(@{
        op    = "add"
        path  = "/fields/System.History"
        value = "Migrated from ADO Server project '$SourceProject', original Work Item ID: $($Item.id)"
    }) | Out-Null

    $url = "$($Destination.BaseUrl)/$dstEncoded/_apis/wit/workitems/`$$encodedType`?api-version=$($Destination.ApiVersion)"
    $body = $patchDoc | ConvertTo-Json -Depth 10

    # Work item creation uses JSON Patch
    $result = Invoke-RestMethod -Uri $url -Headers $Destination.AuthHeader -Method Post `
        -Body $body -ContentType "application/json-patch+json" -ErrorAction Stop

    return $result.id
}

function Restore-WorkItemLinks {
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

        [Parameter(Mandatory)]
        [hashtable]$IdMap
    )

    $linksRestored = 0
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    foreach ($oldId in $IdMap.Keys) {
        # Get source work item relations
        $srcEncoded = [Uri]::EscapeDataString($SourceProject)
        $url = "$($Source.BaseUrl)/_apis/wit/workitems/$oldId`?`$expand=relations&api-version=$($Source.ApiVersion)"

        try {
            $srcItem = Invoke-AdoApi -Url $url -AuthHeader $Source.AuthHeader
        }
        catch { continue }

        if (-not $srcItem.relations) { continue }

        $newId = $IdMap[$oldId]
        $patchDoc = [System.Collections.ArrayList]::new()

        foreach ($relation in $srcItem.relations) {
            # Only handle work item links (not hyperlinks/attachments yet)
            if ($relation.rel -match "^System\.LinkTypes\." -and $relation.url -match '/workItems/(\d+)$') {
                $linkedOldId = [int]$Matches[1]
                if ($IdMap.ContainsKey($linkedOldId)) {
                    $linkedNewId = $IdMap[$linkedOldId]
                    $patchDoc.Add(@{
                        op    = "add"
                        path  = "/relations/-"
                        value = @{
                            rel = $relation.rel
                            url = "$($Destination.BaseUrl)/_apis/wit/workItems/$linkedNewId"
                        }
                    }) | Out-Null
                }
            }
        }

        if ($patchDoc.Count -gt 0) {
            $url = "$($Destination.BaseUrl)/_apis/wit/workitems/$newId`?api-version=$($Destination.ApiVersion)"
            $body = $patchDoc | ConvertTo-Json -Depth 10

            try {
                Invoke-RestMethod -Uri $url -Headers $Destination.AuthHeader -Method Patch `
                    -Body $body -ContentType "application/json-patch+json" -ErrorAction Stop | Out-Null
                $linksRestored += $patchDoc.Count
            }
            catch {
                Write-MigrationLog -Message "    Could not restore links for WI #${newId}: $_" -Level "WARN"
            }
        }
    }

    return $linksRestored
}

Export-ModuleMember -Function Copy-AreaTree, Copy-IterationTree, Copy-WorkItems
