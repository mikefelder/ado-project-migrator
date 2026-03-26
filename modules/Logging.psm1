#Requires -Version 5.1
<#
.SYNOPSIS
    Logging and reporting module for ADO Project Migrator.
#>

$script:LogEntries = [System.Collections.ArrayList]::new()
$script:LogFile = $null

function Initialize-MigrationLog {
    [CmdletBinding()]
    param(
        [string]$LogDirectory = (Join-Path $PSScriptRoot ".." "logs")
    )

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path $LogDirectory "migration_$timestamp.log"
    $script:LogEntries.Clear()

    Write-MigrationLog -Message "Migration log initialized" -Level "INFO"
    return $script:LogFile
}

function Write-MigrationLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    $script:LogEntries.Add($entry) | Out-Null

    if ($script:LogFile) {
        $entry | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    }

    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "Gray" }
    }

    Write-Host $entry -ForegroundColor $color
}

function Write-MigrationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$MigrationResults,

        [string]$ReportDirectory = (Join-Path $PSScriptRoot ".." "logs")
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportFile = Join-Path $ReportDirectory "migration_report_$timestamp.txt"

    $report = @()
    $report += "=" * 70
    $report += "  ADO PROJECT MIGRATION REPORT"
    $report += "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "=" * 70
    $report += ""

    $succeeded = ($MigrationResults | Where-Object { $_.Status -eq "Success" }).Count
    $failed = ($MigrationResults | Where-Object { $_.Status -eq "Failed" }).Count
    $partial = ($MigrationResults | Where-Object { $_.Status -eq "Partial" }).Count

    $report += "SUMMARY"
    $report += "-" * 40
    $report += "  Total Projects:  $($MigrationResults.Count)"
    $report += "  Succeeded:       $succeeded"
    $report += "  Partial:         $partial"
    $report += "  Failed:          $failed"
    $report += ""

    foreach ($result in $MigrationResults) {
        $report += "-" * 70
        $report += "Project: $($result.SourceProject)"
        $report += "  Destination Org:     $($result.DestOrg)"
        $report += "  Destination Project: $($result.DestProject)"
        $report += "  Status:              $($result.Status)"
        $report += "  Duration:            $($result.Duration)"
        $report += ""

        if ($result.Details) {
            foreach ($key in $result.Details.Keys) {
                $report += "  ${key}: $($result.Details[$key])"
            }
        }

        if ($result.Errors -and $result.Errors.Count -gt 0) {
            $report += ""
            $report += "  ERRORS:"
            foreach ($err in $result.Errors) {
                $report += "    - $err"
            }
        }
        $report += ""
    }

    $report += "=" * 70
    $report += "END OF REPORT"

    $report | Out-File -FilePath $reportFile -Encoding UTF8
    Write-MigrationLog -Message "Migration report saved to: $reportFile" -Level "SUCCESS"
    return $reportFile
}

Export-ModuleMember -Function Initialize-MigrationLog, Write-MigrationLog, Write-MigrationReport
