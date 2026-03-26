#Requires -Version 5.1
<#
.SYNOPSIS
    Identity mapping — load a CSV of source→dest user mappings for AssignedTo fields.
    CSV format: SourceUser,DestUser
    e.g.:  john@contoso.com,john.doe@cloud.contoso.com
#>

function Import-IdentityMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    if (-not (Test-Path $CsvPath)) {
        Write-MigrationLog -Message "Identity map file not found: $CsvPath" -Level "ERROR"
        return $null
    }

    $map = @{}
    $rows = Import-Csv -Path $CsvPath -ErrorAction Stop

    # Support both header styles: "SourceUser,DestUser" and "Source,Destination"
    foreach ($row in $rows) {
        $src = if ($row.PSObject.Properties['SourceUser']) { $row.SourceUser }
               elseif ($row.PSObject.Properties['Source']) { $row.Source }
               else { $null }

        $dst = if ($row.PSObject.Properties['DestUser']) { $row.DestUser }
               elseif ($row.PSObject.Properties['Destination']) { $row.Destination }
               else { $null }

        if ($src -and $dst) {
            $map[$src.Trim()] = $dst.Trim()
        }
    }

    Write-MigrationLog -Message "Loaded $($map.Count) identity mapping(s) from '$CsvPath'" -Level "SUCCESS"
    return $map
}

function Resolve-DestinationIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SourceIdentity,

        [hashtable]$IdentityMap = $null
    )

    if (-not $IdentityMap -or $IdentityMap.Count -eq 0) {
        return $null
    }

    # The identity might be a string (display name or email) or a hashtable with uniqueName
    $lookupKeys = @()

    if ($SourceIdentity -is [hashtable] -or $SourceIdentity -is [PSCustomObject]) {
        $obj = if ($SourceIdentity -is [PSCustomObject]) { $SourceIdentity } else { [PSCustomObject]$SourceIdentity }
        if ($obj.uniqueName) { $lookupKeys += $obj.uniqueName }
        if ($obj.displayName) { $lookupKeys += $obj.displayName }
        if ($obj.mailAddress) { $lookupKeys += $obj.mailAddress }
    }
    elseif ($SourceIdentity -is [string]) {
        $lookupKeys += $SourceIdentity
    }

    foreach ($key in $lookupKeys) {
        if ($IdentityMap.ContainsKey($key)) {
            return $IdentityMap[$key]
        }
    }

    return $null
}

function Request-IdentityMapSetup {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "  Identity Mapping (optional)" -ForegroundColor Yellow
    Write-Host "  $('-' * 40)" -ForegroundColor DarkGray
    Write-Host "  Provide a CSV file to map source users to destination users." -ForegroundColor White
    Write-Host "  This ensures 'Assigned To' fields are correctly set." -ForegroundColor White
    Write-Host ""
    Write-Host "  CSV format (with header row):" -ForegroundColor DarkGray
    Write-Host "    SourceUser,DestUser" -ForegroundColor DarkGray
    Write-Host "    john@contoso.com,john.doe@cloudcontoso.com" -ForegroundColor DarkGray
    Write-Host "    Jane Smith,jane.smith@cloudcontoso.com" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Leave blank to skip (AssignedTo fields will be cleared)." -ForegroundColor DarkGray
    Write-Host ""

    $csvPath = Read-Host -Prompt "  Path to identity mapping CSV (or Enter to skip)"

    if ([string]::IsNullOrWhiteSpace($csvPath)) {
        Write-Host "  Skipping identity mapping." -ForegroundColor DarkGray
        return $null
    }

    # Expand ~ and relative paths
    $csvPath = $csvPath.Trim().Trim('"').Trim("'")
    if ($csvPath.StartsWith("~")) {
        $csvPath = $csvPath -replace "^~", $HOME
    }
    if (-not [System.IO.Path]::IsPathRooted($csvPath)) {
        $csvPath = Join-Path (Get-Location) $csvPath
    }

    return Import-IdentityMap -CsvPath $csvPath
}

Export-ModuleMember -Function Import-IdentityMap, Resolve-DestinationIdentity, Request-IdentityMapSetup
