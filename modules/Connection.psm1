#Requires -Version 5.1
<#
.SYNOPSIS
    Connection and authentication module for ADO Project Migrator.
    Handles PAT-based auth for both ADO Server 2022 (on-prem) and ADO Services (cloud).
    No sensitive data is persisted to disk.
#>

function New-AdoAuthHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [securestring]$Pat
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Pat)
    try {
        $plainPat = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plainPat"))
        return @{ Authorization = "Basic $base64" }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-SecurePat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Cyan
    Write-Host "(Input is masked for security)" -ForegroundColor DarkGray
    $secure = Read-Host -AsSecureString -Prompt "PAT"
    return $secure
}

function Test-AdoConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$AuthHeader,

        [string]$ApiVersion = "7.1"
    )

    $url = "$BaseUrl/_apis/projects?`$top=1&api-version=$ApiVersion"

    try {
        $response = Invoke-RestMethod -Uri $url -Headers $AuthHeader -Method Get -ErrorAction Stop
        return @{
            Success = $true
            Message = "Connected successfully. Found $($response.count) project(s)."
        }
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        $msg = switch ($status) {
            401     { "Authentication failed. Check your PAT and ensure it has not expired." }
            403     { "Access denied. Your PAT may lack required scopes (needs Full access or specific scopes)." }
            404     { "Server not found. Verify the URL: $BaseUrl" }
            default { "Connection failed: $($_.Exception.Message)" }
        }
        return @{
            Success = $false
            Message = $msg
        }
    }
}

function Invoke-AdoApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [hashtable]$AuthHeader,

        [string]$Method = "Get",

        [object]$Body = $null,

        [string]$ContentType = "application/json"
    )

    $params = @{
        Uri         = $Url
        Headers     = $AuthHeader
        Method      = $Method
        ContentType = $ContentType
        ErrorAction = "Stop"
    }

    if ($Body -and $Method -ne "Get") {
        if ($Body -is [string]) {
            $params.Body = $Body
        }
        else {
            $params.Body = ($Body | ConvertTo-Json -Depth 20)
        }
    }

    return Invoke-RestMethod @params
}

function Initialize-SourceConnection {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor DarkCyan
    Write-Host "  SOURCE: Azure DevOps Server 2022 (On-Premises)" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "Enter the base URL for your ADO Server instance." -ForegroundColor White
    Write-Host "Example: https://ado-server.contoso.com/DefaultCollection" -ForegroundColor DarkGray
    Write-Host ""

    $sourceUrl = Read-Host -Prompt "Source ADO Server URL"
    $sourceUrl = $sourceUrl.TrimEnd('/')

    Write-Host ""
    Write-Host "Required PAT scopes for source:" -ForegroundColor Yellow
    Write-Host "  - Code (Read)" -ForegroundColor DarkGray
    Write-Host "  - Work Items (Read)" -ForegroundColor DarkGray
    Write-Host "  - Project and Team (Read)" -ForegroundColor DarkGray
    Write-Host "  - Build (Read)" -ForegroundColor DarkGray
    Write-Host "  - Release (Read)" -ForegroundColor DarkGray
    Write-Host ""

    $sourcePat = Read-SecurePat -Prompt "Enter your PAT for the source ADO Server:"

    $authHeader = New-AdoAuthHeader -Pat $sourcePat
    Write-Host ""
    Write-Host "Testing connection to source..." -ForegroundColor Yellow
    $test = Test-AdoConnection -BaseUrl $sourceUrl -AuthHeader $authHeader -ApiVersion "7.1"

    if (-not $test.Success) {
        Write-Host "  FAILED: $($test.Message)" -ForegroundColor Red
        return $null
    }

    Write-Host "  $($test.Message)" -ForegroundColor Green

    return @{
        BaseUrl    = $sourceUrl
        AuthHeader = $authHeader
        Pat        = $sourcePat
        ApiVersion = "7.1"
    }
}

function Initialize-DestinationConnections {
    [CmdletBinding()]
    param()

    $destinations = @()

    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor DarkCyan
    Write-Host "  DESTINATIONS: Azure DevOps Services (Cloud)" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "You can configure one or more destination organizations." -ForegroundColor White
    Write-Host "Projects from the source can be mapped to any of these." -ForegroundColor White
    Write-Host ""

    do {
        $orgName = Read-Host -Prompt "Destination ADO Services Organization name (e.g., 'myorg')"
        $orgName = $orgName.Trim()
        $destUrl = "https://dev.azure.com/$orgName"

        Write-Host ""
        Write-Host "Required PAT scopes for destination:" -ForegroundColor Yellow
        Write-Host "  - Code (Read & Write)" -ForegroundColor DarkGray
        Write-Host "  - Work Items (Read, Write & Manage)" -ForegroundColor DarkGray
        Write-Host "  - Project and Team (Read, Write & Manage)" -ForegroundColor DarkGray
        Write-Host "  - Build (Read & Execute)" -ForegroundColor DarkGray
        Write-Host "  - Release (Read, Write, Execute & Manage)" -ForegroundColor DarkGray
        Write-Host ""

        $destPat = Read-SecurePat -Prompt "Enter your PAT for '$orgName':"

        $authHeader = New-AdoAuthHeader -Pat $destPat
        Write-Host ""
        Write-Host "Testing connection to $orgName..." -ForegroundColor Yellow
        $test = Test-AdoConnection -BaseUrl $destUrl -AuthHeader $authHeader

        if (-not $test.Success) {
            Write-Host "  FAILED: $($test.Message)" -ForegroundColor Red
            $retry = Read-Host "Try again? (y/n)"
            if ($retry -eq 'y') { continue }
        }
        else {
            Write-Host "  $($test.Message)" -ForegroundColor Green
            $destinations += @{
                OrgName    = $orgName
                BaseUrl    = $destUrl
                AuthHeader = $authHeader
                Pat        = $destPat
                ApiVersion = "7.1"
            }
        }

        Write-Host ""
        $addMore = Read-Host "Add another destination organization? (y/n)"

    } while ($addMore -eq 'y')

    if ($destinations.Count -eq 0) {
        Write-Host "No destination organizations configured." -ForegroundColor Red
        return $null
    }

    Write-Host ""
    Write-Host "Configured $($destinations.Count) destination org(s): $(($destinations | ForEach-Object { $_.OrgName }) -join ', ')" -ForegroundColor Green
    return $destinations
}

Export-ModuleMember -Function New-AdoAuthHeader, Read-SecurePat, Test-AdoConnection, Invoke-AdoApi, Initialize-SourceConnection, Initialize-DestinationConnections
