# Linux Software Manager (`lswmgr.sh`)

A full-featured CLI tool for discovering, auditing, and managing installed software across multiple package managers on Linux systems.

## Features

- **Multi-source discovery** — Scans 20+ installation methods:
  - **System packages:** APT, Snap, Flatpak, Nix, Homebrew (Linuxbrew)
  - **Language packages:** pip/pip3, pipx, npm, yarn, cargo (Rust), go, gem (Ruby), composer (PHP), LuaRocks
  - **Version managers:** nvm, pyenv, rbenv, SDKMAN, asdf, mise, rustup
  - **Containers:** Docker images
  - **Manual installs:** /opt, /usr/local, AppImages, git clone+build, untracked binaries
- **Owner tracking** — Run as `sudo` to see which user installed each package; run as normal user to see only your own software
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
git clone https://github.com/Rahiman-K/linux-software-manager.git
cd linux-software-manager
chmod +x lswmgr.sh
```

## Usage

```bash
# Run as normal user (shows only your software)
./lswmgr.sh

# Run as root (shows all users' software with Owner column)
sudo ./lswmgr.sh

# Show top 20 largest packages
./lswmgr.sh --top 20

# Filter by name
./lswmgr.sh --filter "torch"

# Export to JSON
./lswmgr.sh --export json

# Remove a package (with backup)
sudo ./lswmgr.sh --remove torch_fix --source MANUAL --yes

# Detect orphan configs
./lswmgr.sh --orphans

# Restore from backup
./lswmgr.sh --restore

# Dry run (no changes)
./lswmgr.sh --dry-run --remove firefox

# Quiet mode for cron jobs
./lswmgr.sh --quiet --export csv > /dev/null

# Fast load from cache (skip scanning)
./lswmgr.sh --cache

# Force rescan (this is the default anyway)
sudo ./lswmgr.sh --refresh
```

## User vs Root Mode

| Mode | Behavior |
|------|----------|
| `./lswmgr.sh` | Scans only your packages (pip user, pipx, cargo, go, etc.) |
| `sudo ./lswmgr.sh` | Scans all users + system packages, shows **Owner** column |

When running as root:
- Scans every user's home directory for pip, pipx, cargo, go, nvm, pyenv, rbenv, sdkman, asdf, mise, and rustup installations
- Detects conda even if it's not in root's PATH (searches common install locations)
- Displays which user owns each package in the output table
- Automatically filters out service accounts (e.g., `libvirt-qemu`, `nobody`) — only real login users are scanned

## Options

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help message |
| `--cache` | Use cached results for faster loading (default: fresh scan) |
| `--refresh` | Force rescan (same as default, kept for compatibility) |
| `--all` | Show all packages (disable 5MB threshold for APT) |
| `--top N` | Show only top N largest entries |
| `--filter PATTERN` | Filter results by name (supports regex) |
| `--export csv\|json` | Export results to file |
| `--dry-run` | Show what would happen without executing |
| `--remove NAME` | Non-interactive removal by name |
| `--source SOURCE` | Specify source: APT/SNAP/FLATPAK/CONDA/PIP/PIPX/NPM/CARGO/GO/DOCKER/etc. |
| `--yes`, `-y` | Skip confirmation prompts |
| `--restore` | List and restore from backups |
| `--orphans` | Detect orphan config directories |
| `--quiet`, `-q` | No colors, no prompts (cron-friendly) |
| `--log FILE` | Log file path |

## Supported Removal Sources

The tool can remove software from any detected source:

| Source | Removal method |
|--------|---------------|
| APT | `apt remove` |
| SNAP | `snap remove` |
| FLATPAK | `flatpak uninstall` |
| CONDA | `conda env remove` |
| PIP | `pip uninstall` |
| PIPX | `pipx uninstall` |
| NPM | `npm uninstall -g` |
| YARN | `yarn global remove` |
| CARGO | `cargo uninstall` |
| GO | Removes binary |
| GEM | `gem uninstall` |
| COMPOSER | `composer global remove` |
| DOCKER | `docker rmi` |
| NIX | `nix-env --uninstall` |
| BREW | `brew uninstall` |
| APPIMAGE | Removes file |
| MANUAL/UNTRACKED/GIT | Removes file/directory (with safety checks) |
| NVM/PYENV/RBENV/etc. | Removes version directory |

## Backup & Restore

Before removing any software, `lswmgr.sh` offers to create a backup. The backup strategy depends on the source:

| Source | What gets backed up | Restore hint |
|--------|-------------------|--------------|
| APT | Package info, config files from `/etc` | `sudo apt install <package>` |
| SNAP | Snap save + package info | `sudo snap install <package>` |
| FLATPAK | Package metadata | `flatpak install <package>` |
| CONDA | Full env spec (YAML) + directory archive | `conda env create -f <spec.yml>` |
| MANUAL/GIT | `.tar.gz` of the entire directory | Extract to original location |

Backups are stored in `~/.local/share/lswmgr/backups/` with timestamps.

To list and restore from previous backups:
```bash
./lswmgr.sh --restore
```

This shows all available backups and lets you pick one to restore. The tool will suggest the exact reinstall command for each package type.

## License

MIT
