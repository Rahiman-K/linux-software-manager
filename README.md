# Linux Software Manager (`lswmgr.sh`)

A full-featured CLI tool for discovering, auditing, and managing installed software across multiple package managers on Linux systems.

## Features

- **Multi-source discovery** — Scans APT, Snap, Flatpak, Conda, and manually installed software (`/opt`, `/data/apps`)
- **Parallel scanning** with caching for fast repeat runs
- **Backup before removal** — Creates `.tar.gz` archives and Conda env specs before uninstalling
- **Orphan detection** — Finds leftover config directories with no matching installed software
- **Duplicate detection** — Identifies the same software installed from multiple sources
- **Dependency awareness** — Checks `apt rdepends` before removal
- **SystemD service detection** — Shows if software has an associated service
- **Last-used tracking** — Reports how recently software was accessed
- **Interactive TUI** — Uses `fzf`/`dialog` for selection, or falls back to plain mode
- **Export** — Output results as CSV or JSON
- **Dry-run mode** — Preview what would be removed without executing
- **Restore** — List and restore from previous backups
- **Color-coded output** — Size-based color coding with disk usage summary

## Requirements

- Bash 4+
- `bc`, `du`, `stat`, `dpkg`, `apt`
- Optional: `snap`, `flatpak`, `conda`, `fzf`, `dialog`, `jq`

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/linux-software-manager.git
cd linux-software-manager
chmod +x lswmgr.sh
```

## Usage

```bash
# Show top 20 largest packages
./lswmgr.sh --top 20

# Filter by name
./lswmgr.sh --filter "torch"

# Export to JSON
./lswmgr.sh --export json

# Remove a package (with backup)
./lswmgr.sh --remove torch_fix --source MANUAL --yes

# Detect orphan configs
./lswmgr.sh --orphans

# Restore from backup
./lswmgr.sh --restore

# Dry run (no changes)
./lswmgr.sh --dry-run --remove firefox

# Quiet mode for cron jobs
./lswmgr.sh --quiet --export csv > /dev/null
```

## Options

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help message |
| `--refresh` | Force rescan (ignore cache) |
| `--all` | Show all packages (disable 5MB threshold for APT) |
| `--top N` | Show only top N largest entries |
| `--filter PATTERN` | Filter results by name (supports regex) |
| `--export csv\|json` | Export results to file |
| `--dry-run` | Show what would happen without executing |
| `--remove NAME` | Non-interactive removal by name |
| `--source SOURCE` | Specify source: APT/SNAP/FLATPAK/CONDA/MANUAL |
| `--yes`, `-y` | Skip confirmation prompts |
| `--restore` | List and restore from backups |
| `--orphans` | Detect orphan config directories |
| `--quiet`, `-q` | No colors, no prompts (cron-friendly) |
| `--log FILE` | Log file path |

## License

MIT
