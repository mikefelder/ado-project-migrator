#Requires -Version 5.1
<#
.SYNOPSIS
    Git repository migration — clones from source and pushes to destination with full history.
#>

function Copy-GitRepositories {
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

    Write-MigrationLog -Message "  Migrating Git repositories..." -Level "INFO"

    # Verify git is available
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-MigrationLog -Message "  Git is not installed or not in PATH. Cannot migrate repositories." -Level "ERROR"
        return @{ Migrated = 0; Failed = 0 }
    }

    $srcEncoded = [Uri]::EscapeDataString($SourceProject)
    $dstEncoded = [Uri]::EscapeDataString($DestProject)

    # Get source repos
    $srcRepoUrl = "$($Source.BaseUrl)/$srcEncoded/_apis/git/repositories?api-version=$($Source.ApiVersion)"
    $srcRepos = (Invoke-AdoApi -Url $srcRepoUrl -AuthHeader $Source.AuthHeader).value

    if ($srcRepos.Count -eq 0) {
        Write-MigrationLog -Message "  No Git repositories found in source project." -Level "INFO"
        return @{ Migrated = 0; Failed = 0 }
    }

    Write-MigrationLog -Message "  Found $($srcRepos.Count) repository/repositories." -Level "INFO"

    $migrated = 0
    $failed = 0

    # Extract PATs for git credential embedding
    $srcPatPlain = ConvertFrom-SecureStringToPlain -SecureStr $Source.Pat
    $dstPatPlain = ConvertFrom-SecureStringToPlain -SecureStr $Destination.Pat

    # Create a temp directory for cloning
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ado-migration-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    try {
        foreach ($repo in $srcRepos) {
            $repoName = $repo.name
            Write-MigrationLog -Message "    Repo: $repoName" -Level "INFO"

            # Skip if repo is empty (no default branch)
            if (-not $repo.defaultBranch) {
                Write-MigrationLog -Message "      Skipping empty repository '$repoName'." -Level "WARN"
                continue
            }

            try {
                # Create repo in destination if it doesn't exist
                $dstRepoUrl = "$($Destination.BaseUrl)/$dstEncoded/_apis/git/repositories?api-version=$($Destination.ApiVersion)"
                $existingRepos = (Invoke-AdoApi -Url $dstRepoUrl -AuthHeader $Destination.AuthHeader).value
                $existingRepo = $existingRepos | Where-Object { $_.name -eq $repoName }

                if (-not $existingRepo) {
                    Write-MigrationLog -Message "      Creating repository '$repoName' in destination..." -Level "INFO"
                    $createBody = @{
                        name    = $repoName
                        project = @{ id = (Get-DestProjectId -Destination $Destination -ProjectName $DestProject) }
                    }
                    $existingRepo = Invoke-AdoApi -Url $dstRepoUrl -AuthHeader $Destination.AuthHeader -Method "Post" -Body $createBody
                }

                # Build authenticated clone URLs
                $srcCloneUrl = $repo.remoteUrl -replace '(https?://)', "`$1user:$srcPatPlain@"
                $dstCloneUrl = $existingRepo.remoteUrl -replace '(https?://)', "`$1user:$dstPatPlain@"

                $clonePath = Join-Path $tempRoot $repoName

                # Bare clone from source
                Write-MigrationLog -Message "      Cloning from source (bare)..." -Level "INFO"
                $gitOutput = & git clone --bare $srcCloneUrl $clonePath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Git clone failed: $gitOutput"
                }

                # Push mirror to destination
                Write-MigrationLog -Message "      Pushing to destination (mirror)..." -Level "INFO"
                Push-Location $clonePath
                try {
                    $gitOutput = & git push --mirror $dstCloneUrl 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git push failed: $gitOutput"
                    }
                }
                finally {
                    Pop-Location
                }

                Write-MigrationLog -Message "      Repository '$repoName' migrated successfully." -Level "SUCCESS"
                $migrated++
            }
            catch {
                Write-MigrationLog -Message "      Failed to migrate repo '$repoName': $_" -Level "ERROR"
                $failed++
            }
        }
    }
    finally {
        # Clean up temp directory (contains embedded credentials in git config)
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Clear PAT strings from memory
        $srcPatPlain = $null
        $dstPatPlain = $null
        [System.GC]::Collect()
    }

    Write-MigrationLog -Message "  Repositories: $migrated migrated, $failed failed." -Level "SUCCESS"
    return @{ Migrated = $migrated; Failed = $failed }
}

function Get-DestProjectId {
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

function ConvertFrom-SecureStringToPlain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureStr
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStr)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

Export-ModuleMember -Function Copy-GitRepositories
