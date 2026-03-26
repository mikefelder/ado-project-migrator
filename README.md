# ADO Project Migrator

Interactive PowerShell CLI tool for selectively migrating projects from **Azure DevOps Server 2022** (on-premises) to **Azure DevOps Services** (cloud).

## Features

- **Interactive project selection** — browse and pick projects from your source server
- **Multiple destination orgs** — route different projects to different ADO Services organizations
- **Split & merge** — split one source org across multiple destinations, or merge several source projects into one destination project
- **Full Git history** — bare clone + mirror push preserves all branches, tags, and history
- **Work item migration** — areas, iterations, work items with field mapping, links, attachments, and traceability tags
- **Attachment migration** — work item attachments are downloaded from source and re-uploaded to the destination
- **Pipeline definitions** — YAML and Classic build definitions are recreated in the destination
- **Release pipeline migration** — classic release definitions exported/imported via the VSRM API, with environment and artifact remapping
- **Shared query migration** — shared query folder tree and WIQL queries recreated with project reference rewriting
- **Identity mapping** — CSV-based user mapping so `AssignedTo` fields resolve correctly across orgs
- **Process validation** — pre-flight check ensures destination has matching work item types and states before migration begins
- **Dry-run mode** — preview everything the tool would do without making any changes (`-DryRun`)
- **Guided setup** — walks you through PATs, URLs, and required scopes on first run
- **No secrets on disk** — PATs are held in `[SecureString]` memory only, wiped on exit
- **Detailed reporting** — per-project migration report with success/failure breakdown

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell** | 5.1+ (Windows PowerShell) or PowerShell 7+ (cross-platform) |
| **Git** | Must be installed and in `PATH` (for repository migration) |
| **Source PAT** | ADO Server 2022 PAT with scopes: Code (Read), Work Items (Read), Project/Team (Read), Build (Read), Release (Read) |
| **Destination PAT(s)** | ADO Services PAT(s) with scopes: Code (Read/Write), Work Items (Read/Write/Manage), Project/Team (Read/Write/Manage), Build (Read/Execute), Release (Read/Write/Execute/Manage) |
| **Network access** | The machine running the tool needs access to both the on-prem server and `dev.azure.com` |

## Quick Start

```powershell
# Clone or download this tool
cd ado-project-migrator

# Run the migration wizard
./Start-Migration.ps1

# Dry-run mode (no changes made)
./Start-Migration.ps1 -DryRun

# Provide an identity mapping CSV
./Start-Migration.ps1 -IdentityMapPath ./identity-map.csv

# Combine options
./Start-Migration.ps1 -DryRun -IdentityMapPath ./identity-map.csv
```

The tool will guide you through:

1. **Source setup** — enter your ADO Server URL and PAT
2. **Destination setup** — add one or more ADO Services organizations with PATs
3. **Project discovery** — lists all projects on the source with repo/work-item/pipeline counts
4. **Project selection** — pick which projects to migrate (supports ranges like `1-5` or `all`)
5. **Destination mapping** — for each selected project, choose the destination org and project name
6. **Component selection** — choose repos, work items, pipelines, release pipelines, and/or shared queries per project
7. **Identity mapping** — optionally load a CSV to remap users between source and destination
8. **Plan review** — see the full plan and confirm before execution
9. **Migration** — runs the migration with live progress logging
10. **Report** — saves a detailed report to the `logs/` directory

## Directory Structure

```
ado-project-migrator/
├── Start-Migration.ps1              # Main entry point
├── Setup-TestSource.ps1             # Populates a test org with sample data
├── modules/
│   ├── Connection.psm1              # PAT auth, connection testing, API helpers
│   ├── ProjectDiscovery.psm1        # Enumerate projects, repos, work items
│   ├── InteractiveUI.psm1           # Menus, selection, plan builder
│   ├── MigrationEngine.psm1         # Orchestrates per-project migration
│   ├── WorkItemMigration.psm1       # Areas, iterations, work items, links, attachments
│   ├── RepoMigration.psm1           # Git bare clone + mirror push
│   ├── PipelineMigration.psm1       # Build + release pipeline definition migration
│   ├── QueryMigration.psm1          # Shared query tree export/import
│   ├── IdentityMapping.psm1         # CSV-based source→destination user mapping
│   ├── ProcessValidation.psm1       # Pre-flight work item type/state compatibility check
│   └── Logging.psm1                 # Timestamped logging and report generation
├── logs/                            # Auto-created: migration logs and reports
└── README.md
```

## Identity Mapping

When migrating between on-prem and cloud, user identities typically don't match. You can provide a CSV file to map source users to destination users:

```csv
SourceUser,DestUser
john.doe@corp.local,john.doe@company.com
svc-build@corp.local,build-service@company.com
jane.smith@corp.local,jane.smith@company.com
```

Pass it at launch with `-IdentityMapPath ./identity-map.csv`, or the tool will prompt you interactively. Mapped identities are applied to the `System.AssignedTo` field during work item migration. Unmapped users are skipped (the field is left blank rather than causing an error).

## Dry-Run Mode

Run the full wizard without making any changes:

```powershell
./Start-Migration.ps1 -DryRun
```

In dry-run mode, every step logs what **would** happen — project creation, work item counts, repo clones, pipeline definitions, query trees — but nothing is created, cloned, or pushed. Use this to validate your plan and estimate scope before committing.

## Usage Examples

### Migrate specific projects to one org

```
Select projects to migrate:
  [1] ProjectAlpha (Main product)
  [2] ProjectBeta (Internal tools)
  [3] ProjectGamma (Archived)

  Selection: 1,2

  → ProjectAlpha  ──►  mycloud-org/ProjectAlpha
  → ProjectBeta   ──►  mycloud-org/ProjectBeta
```

### Split projects across multiple orgs

```
Configured destinations:
  [1] prod-org (https://dev.azure.com/prod-org)
  [2] internal-org (https://dev.azure.com/internal-org)

  → ProjectAlpha  ──►  prod-org/ProjectAlpha
  → ProjectBeta   ──►  internal-org/InternalTools
```

### Merge projects into an existing destination project

```
Destination project options:
  [1] Use same name: 'ProjectAlpha'
  [2] Merge into an existing project
  [3] Specify a new project name

  Selection: 2
  → Select existing project to merge into: ConsolidatedProject
```

### Select components per project

```
What should be migrated for 'ProjectAlpha'?
  [1] Git Repositories (with full history)
  [2] Work Items (areas, iterations, items, links, attachments)
  [3] Build/Pipeline Definitions
  [4] Release Pipelines (classic)
  [5] Shared Queries
  [6] All of the above

  Selection: 1,2,5
```

## What Gets Migrated

| Component | Details |
|---|---|
| **Git Repositories** | Full clone with all branches, tags, and commit history |
| **Area Paths** | Full tree hierarchy recreated |
| **Iteration Paths** | Full tree with start/finish dates |
| **Work Items** | All standard fields, state, tags, description, acceptance criteria |
| **Work Item Attachments** | Downloaded from source and re-uploaded to destination work items |
| **Work Item Links** | Parent/child, related links restored between migrated items |
| **Traceability Tags** | Each migrated work item tagged `MigratedFrom:<originalId>` |
| **Identity Mapping** | `AssignedTo` fields remapped via CSV (when provided) |
| **YAML Pipelines** | Pipeline definitions recreated (YAML files migrate with the repo) |
| **Classic Build Pipelines** | Definition structure exported and recreated |
| **Classic Release Pipelines** | Release definitions with environments and artifact references |
| **Shared Queries** | Full folder tree and WIQL queries with project reference rewriting |

## Limitations

### Not migrated (requires manual steps)

| Item | Reason |
|---|---|
| **Service connections** | Contain secrets that cannot be read via API; must be recreated manually in the destination |
| **Variable groups / Library** | Secret values cannot be read through the REST API |
| **Secure files** | Cannot be downloaded via API |
| **Agent pools** | Destination-specific infrastructure; need manual setup |
| **Permissions / Security** | Team and user permissions, ACLs, and group memberships must be reconfigured |
| **Test plans / Test suites** | Separate API surface (`_apis/testplan`); not covered in this version |
| **Dashboards / Widgets** | Dashboard layouts and widget configurations are not migrated |
| **Wiki pages** | Published wikis backed by a Git repo can be migrated as a repository; code wikis require manual re-publish |
| **Board settings** | Kanban board columns, swimlanes, card rules, and board configurations |
| **Delivery plans** | Cross-project delivery plan definitions |
| **Notifications / Subscriptions** | Team and personal alert subscriptions |
| **Extensions / Marketplace** | Installed extensions must be manually added to the destination org |

### Work item limitations

- **Work item IDs change** — new IDs are assigned in the destination; the original ID is preserved as a `MigratedFrom:<id>` tag and in the work item history
- **Revision history is not migrated** — only the current state of each work item is copied; the full edit history (all revisions) is not replayed
- **Custom fields** — fields beyond the standard set (Title, State, Description, Tags, Priority, etc.) are not automatically detected; the tool copies a fixed list of known fields
- **Inline images in HTML fields** — images embedded in Description or Acceptance Criteria that reference the source server URL will break; they are not re-hosted
- **Identity resolution without a map** — if no identity mapping CSV is provided, `AssignedTo` fields containing identity objects (hashtables) are skipped to avoid cross-org resolution errors
- **State workflow differences** — if the destination process has different valid states or transitions, work item creation may fail for items in states that don't exist in the destination (the process validation step warns about this)

### Pipeline limitations

- **Service connection references** — pipelines referencing source-org service connections will be created but will not work until connections are recreated with the same names
- **Variable group references** — classic pipelines referencing variable groups will lose those references
- **YAML pipeline triggers** — trigger configurations (CI/PR) are recreated, but webhook-based triggers require re-registration
- **Task version pinning** — if the destination org doesn't have the same task versions installed, pipelines may fail
- **Release pipeline approvals** — release definitions are recreated with automated approvals; manual approval gates and approver assignments must be reconfigured
- **Deployment groups / Environments** — pipeline environment and deployment group targets are not migrated

### Repository limitations

- **Pull requests** — open and closed PR history, comments, and review threads are not migrated; only the Git content is cloned
- **Branch policies** — branch protection rules, required reviewers, and build validation policies must be reconfigured
- **Forks** — forked repository relationships are not preserved
- **Large File Storage (LFS)** — LFS-tracked files are cloned if the source server supports LFS, but LFS configuration may need manual setup on the destination

### General limitations

- **Rate limiting** — large migrations may hit ADO Services API rate limits; the tool does not implement automatic throttling or retry with backoff
- **Org-level settings** — process templates, project-level extensions, and org-level policies are not migrated
- **Cross-project links** — work item links pointing to other projects (not in the migration set) will not be restored
- **Concurrent execution** — the tool migrates projects sequentially; parallel migration is not supported
- **Rollback** — there is no automated rollback; a failed migration leaves partial data in the destination that must be cleaned up manually
- **TFVC repositories** — only Git repositories are supported; Team Foundation Version Control repos are not migrated

## Security

- PATs are stored as `[SecureString]` objects and converted to plaintext only for individual API calls
- Temporary git clones are created in the system temp directory and deleted after migration
- All sensitive variables are nulled and garbage-collected on exit
- No configuration files, credentials, or tokens are written to disk
- Log files contain migration status only — never PATs or authentication data
- The identity mapping CSV should be treated as sensitive if it contains email addresses; it is only read, never modified or copied

## Troubleshooting

| Issue | Solution |
|---|---|
| `401 Unauthorized` | PAT expired or wrong. Regenerate in ADO and re-run. |
| `403 Forbidden` | PAT missing required scopes. Create a new PAT with the scopes listed above. |
| `Git clone failed` | Ensure `git` is installed and the source repo URL is reachable. |
| `Process template not found` | The destination org may not have the same process (Agile/Scrum/CMMI). Create it first. |
| `Work item type not found` | Custom work item types must exist in the destination process before migration. Run with `-DryRun` first to trigger process validation. |
| `VS402371` | Area/iteration node already exists — this is harmless and handled automatically. |
| `Release API unavailable` | The VSRM API may not be enabled or accessible. Release pipeline migration will be skipped with a warning. |
| `Identity not resolved` | Provide an identity mapping CSV with `-IdentityMapPath` to map source users to destination users. |

## Testing

A test data setup script is included to populate an ADO Services organization with sample projects for testing:

```powershell
./Setup-TestSource.ps1
```

This creates three sample projects (AlphaProduct, BetaInternal, GammaArchive) with repos, work items, and pipeline definitions. Use two ADO Services orgs — one as a simulated source, one as the destination — to test end-to-end without needing an on-premises server.

## License

Internal tool — no external license.
