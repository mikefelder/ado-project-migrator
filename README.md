# ADO Project Migrator

Interactive PowerShell CLI tool for selectively migrating projects from **Azure DevOps Server 2022** (on-premises) to **Azure DevOps Services** (cloud).

## Features

- **Interactive project selection** — browse and pick projects from your source server
- **Multiple destination orgs** — route different projects to different ADO Services organizations
- **Split & merge** — split one source org across multiple destinations, or merge several source projects into one destination project
- **Full Git history** — bare clone + mirror push preserves all branches, tags, and history
- **Work item migration** — areas, iterations, work items (with field mapping, links, and traceability tags)
- **Pipeline definitions** — YAML and Classic build definitions are recreated in the destination
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
```

The tool will guide you through:

1. **Source setup** — enter your ADO Server URL and PAT
2. **Destination setup** — add one or more ADO Services organizations with PATs
3. **Project discovery** — lists all projects on the source with repo/work-item/pipeline counts
4. **Project selection** — pick which projects to migrate (supports ranges like `1-5` or `all`)
5. **Destination mapping** — for each selected project, choose the destination org and project name
6. **Component selection** — choose repos, work items, and/or pipelines per project
7. **Plan review** — see the full plan and confirm before execution
8. **Migration** — runs the migration with live progress logging
9. **Report** — saves a detailed report to the `logs/` directory

## Directory Structure

```
ado-project-migrator/
├── Start-Migration.ps1              # Main entry point
├── modules/
│   ├── Connection.psm1              # PAT auth, connection testing, API helpers
│   ├── ProjectDiscovery.psm1        # Enumerate projects, repos, work items
│   ├── InteractiveUI.psm1           # Menus, selection, plan builder
│   ├── MigrationEngine.psm1         # Orchestrates per-project migration
│   ├── WorkItemMigration.psm1       # Areas, iterations, work items, links
│   ├── RepoMigration.psm1           # Git bare clone + mirror push
│   ├── PipelineMigration.psm1       # Build/pipeline definition migration
│   └── Logging.psm1                 # Timestamped logging and report generation
├── logs/                            # Auto-created: migration logs and reports
└── README.md
```

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

## What Gets Migrated

| Component | Details |
|---|---|
| **Git Repositories** | Full clone with all branches, tags, and commit history |
| **Area Paths** | Full tree hierarchy recreated |
| **Iteration Paths** | Full tree with start/finish dates |
| **Work Items** | All standard fields, state, tags, description, acceptance criteria |
| **Work Item Links** | Parent/child, related links restored between migrated items |
| **Traceability Tags** | Each migrated work item tagged `MigratedFrom:<originalId>` |
| **YAML Pipelines** | Pipeline definitions recreated (YAML files migrate with the repo) |
| **Classic Pipelines** | Definition structure exported and recreated |

## What Requires Manual Steps

- **Service connections** — must be recreated in the destination (they contain secrets)
- **Variable groups / Library** — secrets cannot be read via API
- **Agent pools** — destination-specific, need manual setup
- **Permissions / Security** — team and user permissions must be reconfigured
- **Test plans / Test suites** — not covered in this version
- **Dashboards / Widgets** — not covered in this version
- **Wiki** — published wikis are separate repos (can be migrated as repos if named correctly)

## Security

- PATs are stored as `[SecureString]` objects and converted to plaintext only for individual API calls
- Temporary git clones are created in the system temp directory and deleted after migration
- All sensitive variables are nulled and garbage-collected on exit
- No configuration files, credentials, or tokens are written to disk
- Log files contain migration status only — never PATs or authentication data

## Troubleshooting

| Issue | Solution |
|---|---|
| `401 Unauthorized` | PAT expired or wrong. Regenerate in ADO and re-run. |
| `403 Forbidden` | PAT missing required scopes. Create a new PAT with the scopes listed above. |
| `Git clone failed` | Ensure `git` is installed and the source repo URL is reachable. |
| `Process template not found` | The destination org may not have the same process (Agile/Scrum/CMMI). Create it first. |
| `Work item type not found` | Custom work item types must exist in the destination process before migration. |
| `VS402371` | Area/iteration node already exists — this is harmless and handled automatically. |

## License

Internal tool — no external license.
