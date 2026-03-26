#Requires -Version 5.1
<#
.SYNOPSIS
    Process template validation — pre-flight check that destination has matching
    work item types and states before migration begins.
#>

function Test-ProcessCompatibility {
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

    Write-MigrationLog -Message "  Validating process template compatibility..." -Level "INFO"

    $issues = [System.Collections.ArrayList]::new()
    $warnings = [System.Collections.ArrayList]::new()

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    # ── Get source process info ──────────────────────────────────────────────
    $srcProjUrl = "$($Source.BaseUrl)/_apis/projects/$srcEncoded`?includeCapabilities=true&api-version=$($Source.ApiVersion)"
    $srcProj = Invoke-AdoApi -Url $srcProjUrl -AuthHeader $Source.AuthHeader
    $srcProcessName = $srcProj.capabilities.processTemplate.templateName

    # ── Get destination process info ─────────────────────────────────────────
    $dstProjUrl = "$($Destination.BaseUrl)/_apis/projects/$dstEncoded`?includeCapabilities=true&api-version=$($Destination.ApiVersion)"
    $dstProj = $null
    try {
        $dstProj = Invoke-AdoApi -Url $dstProjUrl -AuthHeader $Destination.AuthHeader
    }
    catch {
        # Destination project may not exist yet — that's OK, check against available processes
        Write-MigrationLog -Message "    Destination project not yet created; checking process availability." -Level "INFO"
    }

    if ($dstProj) {
        $dstProcessName = $dstProj.capabilities.processTemplate.templateName
        if ($srcProcessName -ne $dstProcessName) {
            $warnings.Add("Process template mismatch: source='$srcProcessName', destination='$dstProcessName'. Work item types and states may differ.") | Out-Null
        }
    }

    # ── Collect work item types used in source ───────────────────────────────
    $wiqlUrl = "$($Source.BaseUrl)/$srcEncoded/_apis/wit/wiql?api-version=$($Source.ApiVersion)"
    $wiqlBody = @{
        query = "SELECT [System.Id], [System.WorkItemType], [System.State] FROM workitems WHERE [System.TeamProject] = '$SourceProject'"
    } | ConvertTo-Json
    $wiqlResult = Invoke-AdoApi -Url $wiqlUrl -AuthHeader $Source.AuthHeader -Method "Post" -Body $wiqlBody

    $srcWorkItemIds = $wiqlResult.workItems | ForEach-Object { $_.id }

    if ($srcWorkItemIds.Count -eq 0) {
        Write-MigrationLog -Message "    No work items to validate." -Level "INFO"
        return @{ Valid = $true; Issues = @(); Warnings = @() }
    }

    # Sample up to 200 to discover types and states
    $sampleIds = $srcWorkItemIds | Select-Object -First 200
    $idsParam = $sampleIds -join ','
    $getUrl = "$($Source.BaseUrl)/_apis/wit/workitems?ids=$idsParam&fields=System.WorkItemType,System.State&api-version=$($Source.ApiVersion)"
    $items = Invoke-AdoApi -Url $getUrl -AuthHeader $Source.AuthHeader

    $srcTypesUsed = @{}  # type -> set of states
    foreach ($item in $items.value) {
        $wiType = $item.fields.'System.WorkItemType'
        $wiState = $item.fields.'System.State'
        if (-not $srcTypesUsed.ContainsKey($wiType)) {
            $srcTypesUsed[$wiType] = [System.Collections.Generic.HashSet[string]]::new()
        }
        $srcTypesUsed[$wiType].Add($wiState) | Out-Null
    }

    # ── Get destination work item types ──────────────────────────────────────
    # Use the wit/workitemtypes endpoint
    $dstTypesUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/wit/workitemtypes?api-version=$($Destination.ApiVersion)"
    $dstTypes = @{}
    try {
        $dstTypesResult = Invoke-AdoApi -Url $dstTypesUrl -AuthHeader $Destination.AuthHeader
        foreach ($t in $dstTypesResult.value) {
            $stateNames = @()
            if ($t.states) {
                $stateNames = $t.states | ForEach-Object { $_.name }
            }
            $dstTypes[$t.name] = $stateNames
        }
    }
    catch {
        $warnings.Add("Could not retrieve destination work item types: $_. Validation skipped.") | Out-Null
        Write-MigrationLog -Message "    Could not retrieve dest WI types: $_" -Level "WARN"
        return @{ Valid = ($issues.Count -eq 0); Issues = $issues.ToArray(); Warnings = $warnings.ToArray() }
    }

    # ── Compare types and states ─────────────────────────────────────────────
    foreach ($typeName in $srcTypesUsed.Keys) {
        if (-not $dstTypes.ContainsKey($typeName)) {
            $issues.Add("Work item type '$typeName' does not exist in destination. $($srcTypesUsed[$typeName].Count) state(s) used in source.") | Out-Null
            continue
        }

        $dstStates = $dstTypes[$typeName]
        foreach ($state in $srcTypesUsed[$typeName]) {
            if ($state -notin $dstStates) {
                $issues.Add("State '$state' for type '$typeName' does not exist in destination. Available: $($dstStates -join ', ')") | Out-Null
            }
        }
    }

    # ── Report ───────────────────────────────────────────────────────────────
    $valid = $issues.Count -eq 0

    if ($valid -and $warnings.Count -eq 0) {
        Write-MigrationLog -Message "    Process validation passed. All types and states are compatible." -Level "SUCCESS"
    }
    elseif ($valid) {
        Write-MigrationLog -Message "    Process validation passed with $($warnings.Count) warning(s)." -Level "WARN"
        foreach ($w in $warnings) { Write-MigrationLog -Message "      WARNING: $w" -Level "WARN" }
    }
    else {
        Write-MigrationLog -Message "    Process validation FAILED with $($issues.Count) issue(s):" -Level "ERROR"
        foreach ($issue in $issues) { Write-MigrationLog -Message "      ISSUE: $issue" -Level "ERROR" }
        foreach ($w in $warnings) { Write-MigrationLog -Message "      WARNING: $w" -Level "WARN" }
    }

    return @{
        Valid    = $valid
        Issues   = $issues.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Show-ValidationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ValidationResult,

        [Parameter(Mandatory)]
        [string]$SourceProject,

        [Parameter(Mandatory)]
        [string]$DestProject
    )

    Write-Host ""
    Write-Host "  Process Validation: $SourceProject ──► $DestProject" -ForegroundColor $(if ($ValidationResult.Valid) { "Green" } else { "Red" })
    Write-Host "  $('-' * 50)" -ForegroundColor DarkGray

    if ($ValidationResult.Issues.Count -gt 0) {
        Write-Host "  BLOCKING ISSUES ($($ValidationResult.Issues.Count)):" -ForegroundColor Red
        foreach ($issue in $ValidationResult.Issues) {
            Write-Host "    ✗ $issue" -ForegroundColor Red
        }
    }

    if ($ValidationResult.Warnings.Count -gt 0) {
        Write-Host "  WARNINGS ($($ValidationResult.Warnings.Count)):" -ForegroundColor Yellow
        foreach ($w in $ValidationResult.Warnings) {
            Write-Host "    ! $w" -ForegroundColor Yellow
        }
    }

    if ($ValidationResult.Valid -and $ValidationResult.Warnings.Count -eq 0) {
        Write-Host "    All work item types and states are compatible." -ForegroundColor Green
    }

    Write-Host ""
}

Export-ModuleMember -Function Test-ProcessCompatibility, Show-ValidationReport
