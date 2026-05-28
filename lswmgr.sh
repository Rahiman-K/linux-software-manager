#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║          SOFTWARE AUDIT & REMOVAL ENGINE — VERSION 2.0              ║
# ║  Full-featured software management with backup, cache, and TUI      ║
# ╚══════════════════════════════════════════════════════════════════════╝
#
# FEATURES:
#   - Discovery: APT, SNAP, FLATPAK, CONDA, MANUAL
#   - Parallel scanning with caching
#   - Backup before removal (.tar.gz + conda spec)
#   - Disambiguation for duplicate names
#   - Batch removal (comma-separated or size threshold)
#   - Orphan detection (leftover configs)
#   - Duplicate detection (same software, multiple sources)
#   - Dependency awareness (apt rdepends)
#   - SystemD service detection
#   - Last-used tracking
#   - Interactive TUI (fzf/dialog) or plain mode
#   - Export to CSV/JSON
#   - Dry-run mode
#   - Restore from backups
#   - Logging with timestamps
#   - Color-coded size display
#   - Disk summary with category totals
#
# USAGE:
#   ./software_audit_v2.sh [OPTIONS]
#
# OPTIONS:
#   --help              Show this help
#   --refresh           Force rescan (ignore cache)
#   --all               Show all packages (no size threshold)
#   --top N             Show only top N largest entries
#   --filter PATTERN    Filter results by name pattern
#   --export csv|json   Export results to file
#   --dry-run           Show what would be removed without doing it
#   --remove NAME       Non-interactive removal
#   --source SOURCE     Specify source for --remove (APT/SNAP/FLATPAK/CONDA/MANUAL)
#   --yes               Skip confirmation prompts (use with --remove)
#   --restore           List and restore from backups
#   --orphans           Scan for orphan config directories
#   --quiet             No colors, no prompts (cron-friendly)
#   --log FILE          Log actions to file (default: software_audit.log)

# ============================================================
# CONFIGURATION
# ============================================================

VERSION="2.0.0"
BACKUP_DIR="${HOME}/.local/share/lswmgr/backups"
CACHE_FILE="/tmp/lswmgr_cache.json"
CACHE_MAX_AGE=3600  # 1 hour in seconds
LOG_FILE="${HOME}/.local/share/lswmgr/lswmgr.log"
APT_SIZE_THRESHOLD_KB=5120  # 5MB default threshold
SCAN_DIRS=("/opt" "/usr/local" "/snap" "/var/lib/flatpak")

# ============================================================
# GLOBALS
# ============================================================

declare -a SW_NAMES=()
declare -a SW_SOURCES=()
declare -a SW_LOCATIONS=()
declare -a SW_SIZES=()
declare -a SW_SIZES_BYTES=()
declare -a SW_LAST_USED=()
declare -a SW_SERVICES=()
declare -a SW_DUPLICATES=()

# CLI flags
FLAG_REFRESH=0
FLAG_ALL=0
FLAG_TOP=0
FLAG_FILTER=""
FLAG_EXPORT=""
FLAG_DRY_RUN=0
FLAG_REMOVE=""
FLAG_SOURCE=""
FLAG_YES=0
FLAG_RESTORE=0
FLAG_ORPHANS=0
FLAG_QUIET=0
FLAG_HELP=0
TOP_N=0

# ============================================================
# COLORS (disabled in quiet mode)
# ============================================================

setup_colors() {
    if [[ "$FLAG_QUIET" -eq 1 ]] || [[ ! -t 1 ]]; then
        RED="" GREEN="" YELLOW="" CYAN="" MAGENTA="" BOLD="" DIM="" NC=""
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        MAGENTA='\033[0;35m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    fi
}

# ============================================================
# LOGGING
# ============================================================

log_action() {
    local action="$1" target="$2" details="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $action | $target | $details" >> "$LOG_FILE"
}

msg() { [[ "$FLAG_QUIET" -eq 0 ]] && echo -e "$1" >&2; }
err() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

# ============================================================
# CLI ARGUMENT PARSING
# ============================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)       FLAG_HELP=1; shift ;;
            --refresh)       FLAG_REFRESH=1; shift ;;
            --all)           FLAG_ALL=1; shift ;;
            --top)           FLAG_TOP=1; TOP_N="${2:-20}"; shift 2 ;;
            --filter)        FLAG_FILTER="$2"; shift 2 ;;
            --export)        FLAG_EXPORT="$2"; shift 2 ;;
            --dry-run)       FLAG_DRY_RUN=1; shift ;;
            --remove)        FLAG_REMOVE="$2"; shift 2 ;;
            --source)        FLAG_SOURCE="$2"; shift 2 ;;
            --yes|-y)        FLAG_YES=1; shift ;;
            --restore)       FLAG_RESTORE=1; shift ;;
            --orphans)       FLAG_ORPHANS=1; shift ;;
            --quiet|-q)      FLAG_QUIET=1; shift ;;
            --log)           LOG_FILE="$2"; shift 2 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done
}

show_help() {
    cat << 'EOF'
SOFTWARE AUDIT & REMOVAL ENGINE v2.0

USAGE:
  ./software_audit_v2.sh [OPTIONS]

OPTIONS:
  --help, -h            Show this help message
  --refresh             Force rescan (ignore cache)
  --all                 Show all packages (disable 5MB threshold for APT)
  --top N               Show only top N largest entries
  --filter PATTERN      Filter results by name (supports regex)
  --export csv|json     Export results to file
  --dry-run             Show what would happen without executing
  --remove NAME         Non-interactive removal by name
  --source SOURCE       Specify source for --remove (APT/SNAP/FLATPAK/CONDA/MANUAL)
  --yes, -y             Skip confirmation prompts
  --restore             List and restore from backups
  --orphans             Detect orphan config directories
  --quiet, -q           No colors, no prompts (cron-friendly)
  --log FILE            Log file path (default: software_audit.log)

EXAMPLES:
  ./software_audit_v2.sh --top 20
  ./software_audit_v2.sh --filter "torch"
  ./software_audit_v2.sh --remove torch_fix --source MANUAL --yes
  ./software_audit_v2.sh --export json
  ./software_audit_v2.sh --orphans
  ./software_audit_v2.sh --restore
  ./software_audit_v2.sh --quiet --export csv > /dev/null

EOF
    exit 0
}

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

size_to_bytes() {
    local size="$1"
    local num unit
    num=$(echo "$size" | sed 's/[^0-9.]//g')
    unit=$(echo "$size" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

    [[ -z "$num" ]] && echo "0" && return

    case "$unit" in
        K) printf "%.0f" "$(echo "$num * 1024" | bc 2>/dev/null)" ;;
        M) printf "%.0f" "$(echo "$num * 1048576" | bc 2>/dev/null)" ;;
        G) printf "%.0f" "$(echo "$num * 1073741824" | bc 2>/dev/null)" ;;
        T) printf "%.0f" "$(echo "$num * 1099511627776" | bc 2>/dev/null)" ;;
        *) echo "0" ;;
    esac
}

bytes_to_human() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        printf "%.1fG" "$(echo "$bytes / 1073741824" | bc -l)"
    elif [[ "$bytes" -ge 1048576 ]]; then
        printf "%.1fM" "$(echo "$bytes / 1048576" | bc -l)"
    elif [[ "$bytes" -ge 1024 ]]; then
        printf "%.0fK" "$(echo "$bytes / 1024" | bc -l)"
    else
        printf "%dB" "$bytes"
    fi
}

# Color based on size
size_color() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        echo -n "$RED"
    elif [[ "$bytes" -ge 524288000 ]]; then
        echo -n "$YELLOW"
    elif [[ "$bytes" -ge 104857600 ]]; then
        echo -n "$CYAN"
    else
        echo -n "$NC"
    fi
}

# Check last access time
get_last_used() {
    local path="$1"
    if [[ -e "$path" ]]; then
        local atime
        atime=$(stat -c %X "$path" 2>/dev/null)
        if [[ -n "$atime" ]]; then
            local now
            now=$(date +%s)
            local days_ago=$(( (now - atime) / 86400 ))
            if [[ "$days_ago" -gt 365 ]]; then
                echo ">1yr"
            elif [[ "$days_ago" -gt 30 ]]; then
                echo "${days_ago}d"
            else
                echo "recent"
            fi
        else
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

# Check if entry has a systemd service
get_service_status() {
    local name="$1"
    local service_name
    # Check common service name patterns
    for suffix in "" ".service" "d" "d.service"; do
        service_name="${name}${suffix}"
        if systemctl list-unit-files "$service_name" 2>/dev/null | grep -q "$service_name"; then
            local state
            state=$(systemctl is-enabled "$service_name" 2>/dev/null)
            echo "$state"
            return
        fi
    done
    echo "-"
}

# Filtering: skip non-software entries
is_valid_manual_entry() {
    local path="$1"
    local name
    name=$(basename "$path")

    # MUST ignore: archives, logs, temp files
    if [[ "$name" == *.deb ]] || [[ "$name" == *.tar ]] || \
       [[ "$name" == *.zip ]] || [[ "$name" == *.gz ]] || \
       [[ "$name" == *.tar.gz ]] || [[ "$name" == *.tar.xz ]] || \
       [[ "$name" == *.tar.bz2 ]] || [[ "$name" == *.tgz ]] || \
       [[ "$name" == *.log ]] || [[ "$name" == *.tmp ]] || \
       [[ "$name" == *.bak ]] || [[ "$name" == *.old ]]; then
        return 1
    fi

    # MUST include: directories with executables OR AppImage files
    if [[ -d "$path" ]]; then
        if find "$path" -maxdepth 2 -type f -executable 2>/dev/null | head -n 1 | grep -q .; then
            return 0
        fi
        if [[ -d "$path/bin" ]] || [[ -d "$path/lib" ]] || [[ -d "$path/share" ]]; then
            return 0
        fi
        return 1
    elif [[ -f "$path" ]] && [[ "$name" == *.AppImage ]]; then
        return 0
    elif [[ -f "$path" ]] && [[ -x "$path" ]]; then
        return 0
    fi
    return 1
}

add_entry() {
    local name="$1" source="$2" location="$3" size="$4" size_bytes="$5" last_used="$6" service="$7"
    SW_NAMES+=("$name")
    SW_SOURCES+=("$source")
    SW_LOCATIONS+=("$location")
    SW_SIZES+=("$size")
    SW_SIZES_BYTES+=("${size_bytes:-0}")
    SW_LAST_USED+=("${last_used:-N/A}")
    SW_SERVICES+=("${service:--}")
}


# ============================================================
# MODULE 1 — DISCOVERY ENGINE (Parallel Scanning)
# ============================================================

scan_apt() {
    local tmpfile="$1"
    msg "${CYAN}[*] Scanning APT packages...${NC}"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        local size_kb
        size_kb=$(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null)
        [[ -z "$size_kb" || "$size_kb" == "0" ]] && continue

        # Apply size threshold unless --all
        if [[ "$FLAG_ALL" -eq 0 ]] && [[ "$size_kb" -lt "$APT_SIZE_THRESHOLD_KB" ]]; then
            continue
        fi

        local loc
        loc=$(dpkg -L "$pkg" 2>/dev/null | grep -E '^/usr|^/etc|^/opt' | head -n 1)

        local size_display
        if [[ "$size_kb" -ge 1048576 ]]; then
            size_display="$(echo "scale=1; $size_kb/1048576" | bc)G"
        elif [[ "$size_kb" -ge 1024 ]]; then
            size_display="$(echo "scale=1; $size_kb/1024" | bc)M"
        else
            size_display="${size_kb}K"
        fi

        local size_bytes=$(( size_kb * 1024 ))
        local location="${loc:-SYSTEM}"
        local service
        service=$(get_service_status "$pkg")

        echo "${pkg}|APT|${location}|${size_display}|${size_bytes}|N/A|${service}" >> "$tmpfile"
    done < <(apt-mark showmanual 2>/dev/null)
}

scan_snap() {
    local tmpfile="$1"
    if ! command -v snap &>/dev/null; then return; fi
    msg "${CYAN}[*] Scanning SNAP packages...${NC}"

    while IFS= read -r line; do
        local name size
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        [[ -z "$name" || "$name" == "Name" ]] && continue

        local loc="/snap/$name"
        local size_bytes
        size_bytes=$(size_to_bytes "$size")
        local last_used
        last_used=$(get_last_used "$loc")

        echo "${name}|SNAP|${loc}|${size}|${size_bytes:-0}|${last_used}|-" >> "$tmpfile"
    done < <(snap list 2>/dev/null | tail -n +2)
}

scan_flatpak() {
    local tmpfile="$1"
    if ! command -v flatpak &>/dev/null; then return; fi
    msg "${CYAN}[*] Scanning FLATPAK packages...${NC}"

    while IFS= read -r line; do
        local name app_id size
        name=$(echo "$line" | awk '{print $1}')
        app_id=$(echo "$line" | awk '{print $2}')
        size=$(echo "$line" | awk '{print $NF}')

        [[ -z "$name" || "$name" == "Name" ]] && continue

        local loc="/var/lib/flatpak/app/${app_id:-$name}"
        [[ ! -d "$loc" ]] && loc="SYSTEM"

        local size_bytes
        size_bytes=$(size_to_bytes "$size")

        echo "${name}|FLATPAK|${loc}|${size:-0K}|${size_bytes:-0}|N/A|-" >> "$tmpfile"
    done < <(flatpak list --app --columns=name,application,size 2>/dev/null)
}

scan_conda() {
    local tmpfile="$1"
    if ! command -v conda &>/dev/null; then return; fi
    msg "${CYAN}[*] Scanning CONDA environments...${NC}"

    while IFS= read -r line; do
        local name path
        name=$(echo "$line" | awk '{print $1}')
        path=$(echo "$line" | awk '{print $NF}')

        [[ -z "$name" || "$name" == "#" || "$name" == *"#"* ]] && continue
        [[ ! -d "$path" ]] && continue

        local size
        size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        local size_bytes
        size_bytes=$(size_to_bytes "$size")
        local last_used
        last_used=$(get_last_used "$path")

        echo "${name}|CONDA|${path}|${size:-0K}|${size_bytes:-0}|${last_used}|-" >> "$tmpfile"
    done < <(conda env list 2>/dev/null | grep -v '^#' | grep -v '^$')
}

scan_manual() {
    local tmpfile="$1"
    for dir in "${SCAN_DIRS[@]}"; do
        [[ ! -d "$dir" ]] && continue
        msg "${CYAN}[*] Scanning $dir...${NC}"

        for entry in "$dir"/*; do
            [[ -e "$entry" ]] || continue

            local name
            name=$(basename "$entry")

            if ! is_valid_manual_entry "$entry"; then
                continue
            fi

            local size
            size=$(du -sh "$entry" 2>/dev/null | awk '{print $1}')
            local size_bytes
            size_bytes=$(size_to_bytes "$size")
            local last_used
            last_used=$(get_last_used "$entry")
            local service
            service=$(get_service_status "$name")

            echo "${name}|MANUAL|${entry}|${size:-0K}|${size_bytes:-0}|${last_used}|${service}" >> "$tmpfile"
        done
    done
}

# Run all scanners in parallel
run_parallel_scan() {
    local tmp_apt=$(mktemp)
    local tmp_snap=$(mktemp)
    local tmp_flatpak=$(mktemp)
    local tmp_conda=$(mktemp)
    local tmp_manual=$(mktemp)

    scan_apt "$tmp_apt" &
    local pid_apt=$!
    scan_snap "$tmp_snap" &
    local pid_snap=$!
    scan_flatpak "$tmp_flatpak" &
    local pid_flatpak=$!
    scan_conda "$tmp_conda" &
    local pid_conda=$!
    scan_manual "$tmp_manual" &
    local pid_manual=$!

    # Wait for all
    wait $pid_apt $pid_snap $pid_flatpak $pid_conda $pid_manual

    # Load results into arrays
    local tmpfile
    for tmpfile in "$tmp_apt" "$tmp_snap" "$tmp_flatpak" "$tmp_conda" "$tmp_manual"; do
        while IFS='|' read -r name source location size size_bytes last_used service; do
            [[ -z "$name" ]] && continue
            add_entry "$name" "$source" "$location" "$size" "$size_bytes" "$last_used" "$service"
        done < "$tmpfile"
        rm -f "$tmpfile"
    done
}

# ============================================================
# MODULE 2 — CACHE ENGINE
# ============================================================

save_cache() {
    mkdir -p "$(dirname "$CACHE_FILE")"
    local count=${#SW_NAMES[@]}
    {
        echo "{"
        echo "  \"timestamp\": $(date +%s),"
        echo "  \"version\": \"$VERSION\","
        echo "  \"entries\": ["
        for ((i=0; i<count; i++)); do
            local comma=","
            [[ $i -eq $((count-1)) ]] && comma=""
            # Escape quotes in values
            local ename="${SW_NAMES[$i]//\"/\\\"}"
            local esource="${SW_SOURCES[$i]//\"/\\\"}"
            local eloc="${SW_LOCATIONS[$i]//\"/\\\"}"
            local esize="${SW_SIZES[$i]//\"/\\\"}"
            local elastused="${SW_LAST_USED[$i]//\"/\\\"}"
            local eservice="${SW_SERVICES[$i]//\"/\\\"}"
            echo "    {\"name\":\"$ename\",\"source\":\"$esource\",\"location\":\"$eloc\",\"size\":\"$esize\",\"size_bytes\":${SW_SIZES_BYTES[$i]:-0},\"last_used\":\"$elastused\",\"service\":\"$eservice\"}$comma"
        done
        echo "  ]"
        echo "}"
    } > "$CACHE_FILE"
}

load_cache() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    # Check age
    local cache_time
    cache_time=$(grep '"timestamp"' "$CACHE_FILE" | grep -o '[0-9]*')
    local now
    now=$(date +%s)
    local age=$(( now - cache_time ))

    if [[ "$age" -gt "$CACHE_MAX_AGE" ]]; then
        return 1
    fi

    msg "${GREEN}[*] Loading from cache (age: ${age}s)...${NC}"

    # Parse JSON cache (simple line-by-line parsing)
    while IFS= read -r line; do
        if [[ "$line" == *'"name"'* ]]; then
            local name source location size size_bytes last_used service
            name=$(echo "$line" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            source=$(echo "$line" | grep -o '"source":"[^"]*"' | cut -d'"' -f4)
            location=$(echo "$line" | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
            size=$(echo "$line" | grep -o '"size":"[^"]*"' | cut -d'"' -f4)
            size_bytes=$(echo "$line" | grep -o '"size_bytes":[0-9]*' | cut -d: -f2)
            last_used=$(echo "$line" | grep -o '"last_used":"[^"]*"' | cut -d'"' -f4)
            service=$(echo "$line" | grep -o '"service":"[^"]*"' | cut -d'"' -f4)
            add_entry "$name" "$source" "$location" "$size" "$size_bytes" "$last_used" "$service"
        fi
    done < "$CACHE_FILE"

    return 0
}

# ============================================================
# MODULE 3 — DUPLICATE DETECTION
# ============================================================

detect_duplicates() {
    local count=${#SW_NAMES[@]}
    declare -A name_map

    for ((i=0; i<count; i++)); do
        local normalized
        normalized=$(echo "${SW_NAMES[$i]}" | tr '-' '_' | tr '[:upper:]' '[:lower:]' | sed 's/[._-]//g')

        if [[ -n "${name_map[$normalized]}" ]]; then
            local prev_idx="${name_map[$normalized]}"
            SW_DUPLICATES[$i]="DUP:${SW_NAMES[$prev_idx]}(${SW_SOURCES[$prev_idx]})"
            SW_DUPLICATES[$prev_idx]="DUP:${SW_NAMES[$i]}(${SW_SOURCES[$i]})"
        else
            name_map["$normalized"]="$i"
        fi
    done
}

# ============================================================
# MODULE 4 — ORPHAN DETECTION
# ============================================================

scan_orphans() {
    msg "${CYAN}[*] Scanning for orphan config directories...${NC}"
    echo ""
    echo -e "${BOLD}ORPHAN CONFIG DIRECTORIES${NC}"
    echo -e "${DIM}(Configs with no matching installed software)${NC}"
    echo ""

    local orphan_count=0
    local orphan_size_total=0

    local config_dirs=(
        "$HOME/.config"
        "$HOME/.local/share"
        "$HOME/.cache"
    )

    # Build a lookup of known software names (normalized)
    declare -A known_software
    for ((i=0; i<${#SW_NAMES[@]}; i++)); do
        local norm
        norm=$(echo "${SW_NAMES[$i]}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
        known_software["$norm"]=1
        # Also add without special chars
        norm=$(echo "${SW_NAMES[$i]}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        known_software["$norm"]=1
    done

    # Also add APT packages (all of them, not just shown ones)
    while IFS= read -r pkg; do
        local norm
        norm=$(echo "$pkg" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
        known_software["$norm"]=1
        norm=$(echo "$pkg" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        known_software["$norm"]=1
    done < <(dpkg --get-selections 2>/dev/null | awk '{print $1}' | cut -d: -f1)

    printf "%-35s %-25s %10s\n" "Directory" "Location" "Size"
    printf "%-35s %-25s %10s\n" "-----------------------------------" "-------------------------" "----------"

    for config_dir in "${config_dirs[@]}"; do
        [[ ! -d "$config_dir" ]] && continue

        for entry in "$config_dir"/*/; do
            [[ ! -d "$entry" ]] && continue
            local dirname
            dirname=$(basename "$entry")

            # Normalize for comparison
            local norm
            norm=$(echo "$dirname" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
            local norm2
            norm2=$(echo "$dirname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')

            # Skip if matches known software
            [[ -n "${known_software[$norm]}" ]] && continue
            [[ -n "${known_software[$norm2]}" ]] && continue

            # Skip very common/system dirs
            case "$dirname" in
                dconf|ibus|pulse|dbus*|glib*|gtk*|mime|fontconfig|user-dirs*|enchant|procps) continue ;;
            esac

            local size
            size=$(du -sh "$entry" 2>/dev/null | awk '{print $1}')
            local size_bytes
            size_bytes=$(size_to_bytes "$size")

            # Only show if > 1MB
            if [[ "${size_bytes:-0}" -gt 1048576 ]]; then
                printf "%-35s %-25s %10s\n" "$dirname" "$config_dir" "$size"
                orphan_count=$((orphan_count + 1))
                orphan_size_total=$((orphan_size_total + size_bytes))
            fi
        done
    done

    echo ""
    echo -e "${CYAN}Orphans found: $orphan_count | Total size: $(bytes_to_human $orphan_size_total)${NC}"
}


# ============================================================
# MODULE 5 — DISPLAY ENGINE
# ============================================================

display_disk_summary() {
    echo ""
    # Overall disk usage
    local disk_total disk_used disk_free disk_pct
    read -r disk_total disk_used disk_free disk_pct <<< $(df -h / 2>/dev/null | awk 'NR==2{print $2, $3, $4, $5}')

    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  DISK OVERVIEW                                               ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Total: ${CYAN}${disk_total}${NC}  Used: ${YELLOW}${disk_used} (${disk_pct})${NC}  Free: ${GREEN}${disk_free}${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

    # Category totals
    declare -A cat_count cat_bytes
    for ((i=0; i<${#SW_NAMES[@]}; i++)); do
        local src="${SW_SOURCES[$i]}"
        cat_count["$src"]=$(( ${cat_count["$src"]:-0} + 1 ))
        cat_bytes["$src"]=$(( ${cat_bytes["$src"]:-0} + ${SW_SIZES_BYTES[$i]:-0} ))
    done

    echo ""
    echo -e "${BOLD}CATEGORY TOTALS:${NC}"
    for src in APT SNAP FLATPAK CONDA MANUAL; do
        if [[ -n "${cat_count[$src]}" ]]; then
            printf "  ${CYAN}%-10s${NC} %3d packages  │  %s\n" \
                "$src" "${cat_count[$src]}" "$(bytes_to_human ${cat_bytes[$src]:-0})"
        fi
    done
    echo ""
}

display_results() {
    local count=${#SW_NAMES[@]}

    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}No software found.${NC}"
        return
    fi

    # Build sortable index array
    local -a indices=()
    for ((i=0; i<count; i++)); do
        # Apply filter if set
        if [[ -n "$FLAG_FILTER" ]]; then
            if ! echo "${SW_NAMES[$i]}" | grep -qi "$FLAG_FILTER"; then
                continue
            fi
        fi
        indices+=("$i")
    done

    # Sort indices by size_bytes descending
    IFS=$'\n' sorted_indices=($(
        for i in "${indices[@]}"; do
            echo "${SW_SIZES_BYTES[$i]:-0} $i"
        done | sort -t' ' -k1 -n -r | awk '{print $2}'
    ))
    unset IFS

    # Apply --top N
    local display_count=${#sorted_indices[@]}
    if [[ "$FLAG_TOP" -eq 1 ]] && [[ "$TOP_N" -gt 0 ]] && [[ "$display_count" -gt "$TOP_N" ]]; then
        sorted_indices=("${sorted_indices[@]:0:$TOP_N}")
        display_count=$TOP_N
    fi

    # Display disk summary
    display_disk_summary

    # Print header
    printf "${BOLD}%-30s %-10s %-35s %10s %8s %8s${NC}\n" \
        "Software" "Source" "Location" "Size" "Used" "Service"
    printf "%-30s %-10s %-35s %10s %8s %8s\n" \
        "──────────────────────────────" "──────────" "───────────────────────────────────" "──────────" "────────" "────────"

    # Print sorted entries
    for i in "${sorted_indices[@]}"; do
        local color
        color=$(size_color "${SW_SIZES_BYTES[$i]:-0}")

        local dup_marker=""
        if [[ -n "${SW_DUPLICATES[$i]}" ]]; then
            dup_marker=" ${MAGENTA}⚠${NC}"
        fi

        printf "${color}%-30s${NC} %-10s %-35s ${color}%10s${NC} %8s %8s%b\n" \
            "${SW_NAMES[$i]}" \
            "${SW_SOURCES[$i]}" \
            "${SW_LOCATIONS[$i]}" \
            "${SW_SIZES[$i]}" \
            "${SW_LAST_USED[$i]}" \
            "${SW_SERVICES[$i]}" \
            "$dup_marker"
    done

    echo ""
    echo -e "${CYAN}Showing: $display_count / $count entries${NC}"

    # Show duplicate warnings
    local dup_found=0
    for ((i=0; i<count; i++)); do
        if [[ -n "${SW_DUPLICATES[$i]}" ]]; then
            if [[ "$dup_found" -eq 0 ]]; then
                echo ""
                echo -e "${MAGENTA}⚠ DUPLICATE DETECTIONS:${NC}"
                dup_found=1
            fi
            echo -e "  ${MAGENTA}${SW_NAMES[$i]} (${SW_SOURCES[$i]}) ↔ ${SW_DUPLICATES[$i]}${NC}"
        fi
    done
}

# ============================================================
# MODULE 6 — EXPORT ENGINE
# ============================================================

export_results() {
    local format="$1"
    local count=${#SW_NAMES[@]}
    local outfile

    case "$format" in
        csv)
            outfile="./software_audit_export.csv"
            {
                echo "Name,Source,Location,Size,Size_Bytes,Last_Used,Service"
                for ((i=0; i<count; i++)); do
                    echo "\"${SW_NAMES[$i]}\",\"${SW_SOURCES[$i]}\",\"${SW_LOCATIONS[$i]}\",\"${SW_SIZES[$i]}\",${SW_SIZES_BYTES[$i]:-0},\"${SW_LAST_USED[$i]}\",\"${SW_SERVICES[$i]}\""
                done
            } > "$outfile"
            ;;
        json)
            outfile="./software_audit_export.json"
            save_cache  # Reuse cache format
            cp "$CACHE_FILE" "$outfile"
            ;;
        *)
            err "Unknown export format: $format (use csv or json)"
            return 1
            ;;
    esac

    msg "${GREEN}[✓] Exported to: $outfile${NC}"
    log_action "EXPORT" "$format" "$outfile"
}

# ============================================================
# MODULE 7 — BACKUP ENGINE
# ============================================================

create_backup() {
    local name="$1" source="$2" location="$3"

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="${name}_${source}_${timestamp}.tar.gz"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    msg "${CYAN}[*] Creating backup...${NC}"

    # CONDA: export env spec
    if [[ "$source" == "CONDA" ]]; then
        local spec_file="${BACKUP_DIR}/${name}_${timestamp}_spec.yml"
        conda env export --name "$name" > "$spec_file" 2>/dev/null
        if [[ -f "$spec_file" ]]; then
            msg "${GREEN}    [✓] Conda env spec: $spec_file${NC}"
        fi
    fi

    # Source-specific backup strategies
    if [[ "$source" == "APT" ]]; then
        local pkg_info="${BACKUP_DIR}/${name}_${timestamp}_apt_info.txt"
        {
            echo "# APT Package Backup Info"
            echo "# Package: $name"
            echo "# Date: $(date)"
            echo "# Restore with: sudo apt install $name"
            echo ""
            echo "## Installed files:"
            dpkg -L "$name" 2>/dev/null
            echo ""
            echo "## Package info:"
            dpkg -s "$name" 2>/dev/null
        } > "$pkg_info"

        # Backup config files from /etc
        local etc_files
        etc_files=$(dpkg -L "$name" 2>/dev/null | grep '^/etc/')
        if [[ -n "$etc_files" ]]; then
            local config_backup="${BACKUP_DIR}/${name}_${timestamp}_configs.tar.gz"
            echo "$etc_files" | tar -czf "$config_backup" -T - 2>/dev/null
            [[ -f "$config_backup" ]] && msg "${GREEN}    [✓] Config backup: $config_backup${NC}"
        fi

        msg "${GREEN}    [✓] APT info saved: $pkg_info${NC}"
        msg "${YELLOW}    [i] Restore: sudo apt install $name${NC}"
        log_action "BACKUP" "$name" "APT info → $pkg_info"
        return 0

    elif [[ "$source" == "SNAP" ]]; then
        local snap_info="${BACKUP_DIR}/${name}_${timestamp}_snap_info.txt"
        {
            echo "# SNAP Package Backup"
            echo "# Package: $name"
            echo "# Date: $(date)"
            echo "# Restore: sudo snap install $name"
            echo ""
            snap info "$name" 2>/dev/null
        } > "$snap_info"
        sudo snap save "$name" 2>/dev/null
        msg "${GREEN}    [✓] Snap info: $snap_info${NC}"
        log_action "BACKUP" "$name" "SNAP → $snap_info"
        return 0

    elif [[ "$source" == "FLATPAK" ]]; then
        local flatpak_info="${BACKUP_DIR}/${name}_${timestamp}_flatpak_info.txt"
        {
            echo "# FLATPAK Package Backup"
            echo "# Package: $name"
            echo "# Date: $(date)"
            echo "# Restore: flatpak install $name"
            echo ""
            flatpak info "$name" 2>/dev/null
        } > "$flatpak_info"
        msg "${GREEN}    [✓] Flatpak info: $flatpak_info${NC}"
        log_action "BACKUP" "$name" "FLATPAK → $flatpak_info"
        return 0

    elif [[ -e "$location" ]]; then
        local parent_dir base_name
        parent_dir=$(dirname "$location")
        base_name=$(basename "$location")

        if tar -czf "$backup_path" -C "$parent_dir" "$base_name" 2>/dev/null; then
            local backup_size
            backup_size=$(du -sh "$backup_path" 2>/dev/null | awk '{print $1}')
            msg "${GREEN}    [✓] Backup: $backup_path ($backup_size)${NC}"
            log_action "BACKUP" "$name" "$backup_path ($backup_size)"
            return 0
        else
            err "Failed to create backup archive."
            return 1
        fi
    else
        msg "${YELLOW}    [i] No backupable path found.${NC}"
        return 1
    fi
}

# ============================================================
# MODULE 8 — RESTORE ENGINE
# ============================================================

restore_from_backup() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${YELLOW}No backups found in $BACKUP_DIR${NC}"
        return
    fi

    echo ""
    echo -e "${BOLD}AVAILABLE BACKUPS:${NC}"
    echo ""

    local -a backup_files=()
    local idx=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        idx=$((idx + 1))
        backup_files+=("$file")
        local bname bsize
        bname=$(basename "$file")
        bsize=$(du -sh "$file" 2>/dev/null | awk '{print $1}')
        printf "  ${CYAN}%2d)${NC} %-60s %8s\n" "$idx" "$bname" "$bsize"
    done < <(find "$BACKUP_DIR" -name "*.tar.gz" -o -name "*_spec.yml" -o -name "*_apt_info.txt" 2>/dev/null | sort -r)

    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}  No backup files found.${NC}"
        return
    fi

    echo ""
    read -p "Select backup to restore (number, or Enter to skip): " </dev/tty selection

    if [[ -z "$selection" ]]; then
        echo "Skipped."
        return
    fi

    if [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "$idx" ]]; then
        err "Invalid selection."
        return
    fi

    local chosen="${backup_files[$((selection-1))]}"
    local chosen_name
    chosen_name=$(basename "$chosen")

    echo ""
    echo -e "${CYAN}Selected: $chosen_name${NC}"

    if [[ "$chosen" == *.tar.gz ]]; then
        read -p "Restore to which directory? (default: original location): " </dev/tty dest
        if [[ -z "$dest" ]]; then
            # Try to guess from filename
            if [[ "$chosen_name" == *"MANUAL"* ]]; then
                dest="/opt"
            elif [[ "$chosen_name" == *"CONDA"* ]]; then
                dest="$(conda info --base 2>/dev/null)/envs"
            else
                dest="/tmp/restore_$(date +%s)"
            fi
        fi
        mkdir -p "$dest"
        echo -e "${CYAN}[*] Extracting to $dest...${NC}"
        if tar -xzf "$chosen" -C "$dest" 2>/dev/null; then
            echo -e "${GREEN}[✓] Restored to $dest${NC}"
            log_action "RESTORE" "$chosen_name" "→ $dest"
        else
            err "Failed to extract backup."
        fi
    elif [[ "$chosen" == *_spec.yml ]]; then
        echo -e "${CYAN}[*] Recreating conda environment from spec...${NC}"
        if conda env create -f "$chosen" 2>&1; then
            echo -e "${GREEN}[✓] Conda environment restored.${NC}"
            log_action "RESTORE" "$chosen_name" "conda env create"
        else
            err "Failed to restore conda environment."
        fi
    elif [[ "$chosen" == *_apt_info.txt ]]; then
        local pkg
        pkg=$(grep "^# Package:" "$chosen" | awk '{print $3}')
        echo -e "${CYAN}[*] Reinstalling APT package: $pkg${NC}"
        if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
            echo -e "${YELLOW}[DRY-RUN] Would run: sudo apt install -y $pkg${NC}"
        else
            sudo apt install -y "$pkg"
            log_action "RESTORE" "$pkg" "apt install"
        fi
    fi
}


# ============================================================
# MODULE 9 — REMOVAL ENGINE (with disambiguation + batch)
# ============================================================

find_matches() {
    local target="$1"
    local -a results=()

    # Exact match
    for ((i=0; i<${#SW_NAMES[@]}; i++)); do
        if [[ "${SW_NAMES[$i]}" == "$target" ]]; then
            results+=("$i")
        fi
    done

    # Fuzzy match (normalize - _ and case)
    local target_norm
    target_norm=$(echo "$target" | tr '-' '_' | tr '[:upper:]' '[:lower:]')

    for ((i=0; i<${#SW_NAMES[@]}; i++)); do
        local name_norm
        name_norm=$(echo "${SW_NAMES[$i]}" | tr '-' '_' | tr '[:upper:]' '[:lower:]')
        if [[ "$name_norm" == "$target_norm" ]]; then
            local already=0
            for idx in "${results[@]}"; do
                [[ "$idx" -eq "$i" ]] && already=1 && break
            done
            [[ "$already" -eq 0 ]] && results+=("$i")
        fi
    done

    echo "${results[@]}"
}

show_apt_dependencies() {
    local name="$1"
    echo ""
    echo -e "${YELLOW}Reverse dependencies (packages that depend on '$name'):${NC}"
    local rdeps
    rdeps=$(apt-cache rdepends "$name" 2>/dev/null | grep -v "^$name" | grep -v "Reverse" | head -10)
    if [[ -n "$rdeps" ]]; then
        echo "$rdeps" | sed 's/^/  /'
        local total
        total=$(apt-cache rdepends "$name" 2>/dev/null | grep -v "^$name" | grep -v "Reverse" | wc -l)
        [[ "$total" -gt 10 ]] && echo -e "  ${DIM}... and $((total-10)) more${NC}"
    else
        echo -e "  ${GREEN}None (safe to remove)${NC}"
    fi
    echo ""
}

remove_single() {
    local found="$1" target="$2"

    local name="${SW_NAMES[$found]}"
    local source="${SW_SOURCES[$found]}"
    local location="${SW_LOCATIONS[$found]}"
    local size="${SW_SIZES[$found]}"

    # Show APT dependencies
    if [[ "$source" == "APT" ]] && [[ "$FLAG_YES" -eq 0 ]]; then
        show_apt_dependencies "$name"
    fi

    # CONDA: ask env vs package removal
    local conda_mode="env"
    if [[ "$source" == "CONDA" ]] && [[ "$FLAG_YES" -eq 0 ]]; then
        echo ""
        echo -e "${YELLOW}CONDA removal options for '$name':${NC}"
        echo -e "  ${CYAN}1)${NC} Remove entire environment '$name'"
        echo -e "  ${CYAN}2)${NC} Remove only package '$target' from env '$name'"
        echo ""
        read -p "Select (1 or 2): " </dev/tty conda_choice
        [[ "$conda_choice" == "2" ]] && conda_mode="package"
    fi

    # Confirmation display
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║            REMOVAL CONFIRMATION                      ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC} Software : ${CYAN}$name${NC}"
    echo -e "${YELLOW}║${NC} Source   : ${CYAN}$source${NC}"
    echo -e "${YELLOW}║${NC} Location : ${CYAN}$location${NC}"
    echo -e "${YELLOW}║${NC} Size     : ${CYAN}$size${NC}"
    if [[ "$source" == "CONDA" ]]; then
        if [[ "$conda_mode" == "env" ]]; then
            echo -e "${YELLOW}║${NC} Action   : ${RED}Remove ENTIRE environment${NC}"
        else
            echo -e "${YELLOW}║${NC} Action   : ${CYAN}Remove package only${NC}"
        fi
    fi
    if [[ "${SW_SERVICES[$found]}" != "-" ]]; then
        echo -e "${YELLOW}║${NC} Service  : ${RED}${SW_SERVICES[$found]} (will need systemctl disable)${NC}"
    fi
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"

    # DRY RUN check
    if [[ "$FLAG_DRY_RUN" -eq 1 ]]; then
        echo -e "${YELLOW}[DRY-RUN] Would remove '$name' ($source) — no action taken.${NC}"
        log_action "DRY-RUN" "$name" "$source | $location | $size"
        return 0
    fi

    # Backup prompt
    local do_backup="n"
    if [[ "$FLAG_YES" -eq 0 ]]; then
        read -p "Create backup before removal? (y/n): " </dev/tty do_backup
    fi

    if [[ "$do_backup" == "y" ]]; then
        create_backup "$name" "$source" "$location"
        if [[ $? -ne 0 ]]; then
            read -p "Backup failed. Continue anyway? (y/n): " </dev/tty force
            [[ "$force" != "y" ]] && echo "Cancelled." && return 0
        fi
    fi

    # Final confirmation
    if [[ "$FLAG_YES" -eq 0 ]]; then
        read -p "Confirm removal of '$name'? (y/n): " </dev/tty confirm
        [[ "$confirm" != "y" ]] && echo -e "${GREEN}Cancelled.${NC}" && return 0
    fi

    # Record disk before
    local disk_before
    disk_before=$(df / --output=avail 2>/dev/null | tail -1 | tr -d ' ')

    # Disable systemd service if present
    if [[ "${SW_SERVICES[$found]}" != "-" ]]; then
        local svc_name="${name}.service"
        msg "${CYAN}[*] Disabling service $svc_name...${NC}"
        sudo systemctl stop "$svc_name" 2>/dev/null
        sudo systemctl disable "$svc_name" 2>/dev/null
    fi

    # Execute removal
    case "$source" in
        APT)
            msg "${CYAN}[*] Removing via apt...${NC}"
            if sudo apt remove -y "$name" 2>/dev/null; then
                msg "${GREEN}[✓] Removed '$name' via apt.${NC}"
                # Offer autoremove
                if [[ "$FLAG_YES" -eq 0 ]]; then
                    read -p "Run apt autoremove to clean orphaned deps? (y/n): " </dev/tty autoremove
                    if [[ "$autoremove" == "y" ]]; then
                        sudo apt autoremove -y 2>/dev/null
                        msg "${GREEN}[✓] Autoremove complete.${NC}"
                    fi
                fi
            else
                err "Failed to remove '$name' via apt."
                return 1
            fi
            ;;
        SNAP)
            msg "${CYAN}[*] Removing via snap...${NC}"
            if sudo snap remove "$name" 2>/dev/null; then
                msg "${GREEN}[✓] Removed '$name' via snap.${NC}"
            else
                err "Failed to remove '$name' via snap."
                return 1
            fi
            ;;
        FLATPAK)
            msg "${CYAN}[*] Removing via flatpak...${NC}"
            if flatpak uninstall -y "$name" 2>/dev/null; then
                msg "${GREEN}[✓] Removed '$name' via flatpak.${NC}"
            else
                err "Failed to remove '$name' via flatpak."
                return 1
            fi
            ;;
        CONDA)
            eval "$(conda shell.bash hook 2>/dev/null)"
            if [[ "$CONDA_DEFAULT_ENV" == "$name" ]]; then
                msg "${CYAN}[*] Deactivating current env...${NC}"
                conda deactivate 2>/dev/null
            fi

            if [[ "$conda_mode" == "env" ]]; then
                msg "${CYAN}[*] Removing entire conda env '$name'...${NC}"
                if conda env remove --name "$name" -y 2>&1; then
                    [[ -d "$location" ]] && rm -rf "$location"
                    msg "${GREEN}[✓] Conda env '$name' removed.${NC}"
                else
                    err "Failed to remove conda env '$name'."
                    return 1
                fi
            else
                msg "${CYAN}[*] Removing package '$target' from env '$name'...${NC}"
                local pkg_alt
                pkg_alt=$(echo "$target" | tr '_' '-')
                if conda remove --name "$name" "$target" -y 2>/dev/null; then
                    msg "${GREEN}[✓] Removed '$target' from env '$name'.${NC}"
                elif conda remove --name "$name" "$pkg_alt" -y 2>/dev/null; then
                    msg "${GREEN}[✓] Removed '$pkg_alt' from env '$name'.${NC}"
                else
                    msg "${YELLOW}[*] Trying pip uninstall...${NC}"
                    if conda run --name "$name" pip uninstall -y "$target" 2>/dev/null; then
                        msg "${GREEN}[✓] Removed via pip.${NC}"
                    else
                        err "Failed to remove package."
                        return 1
                    fi
                fi
            fi
            ;;
        MANUAL)
            if [[ ! -e "$location" ]]; then
                err "Path does not exist: $location"
                return 1
            fi
            case "$location" in
                /|/usr|/etc|/var|/bin|/sbin|/lib|/lib64|/boot|/proc|/sys|/dev)
                    err "BLOCKED: Refusing to remove system-critical path: $location"
                    return 1
                    ;;
            esac
            msg "${CYAN}[*] Removing $location...${NC}"
            if rm -rf "$location"; then
                msg "${GREEN}[✓] Removed '$name' from $location.${NC}"
            else
                err "Failed to remove '$name'. Check permissions."
                return 1
            fi
            ;;
        *)
            err "Unknown source: $source"
            return 1
            ;;
    esac

    # Disk reclaimed summary
    local disk_after
    disk_after=$(df / --output=avail 2>/dev/null | tail -1 | tr -d ' ')
    if [[ -n "$disk_before" ]] && [[ -n "$disk_after" ]]; then
        local reclaimed=$(( (disk_after - disk_before) * 1024 ))
        if [[ "$reclaimed" -gt 0 ]]; then
            echo -e "${GREEN}[i] Disk reclaimed: $(bytes_to_human $reclaimed)${NC}"
        fi
    fi

    log_action "REMOVE" "$name" "$source | $location | $size"

    # Invalidate cache
    rm -f "$CACHE_FILE"
}

remove_software() {
    # Non-interactive mode
    if [[ -n "$FLAG_REMOVE" ]]; then
        local matches
        matches=($(find_matches "$FLAG_REMOVE"))

        if [[ ${#matches[@]} -eq 0 ]]; then
            err "Software '$FLAG_REMOVE' not found."
            return 1
        fi

        # If --source specified, filter
        if [[ -n "$FLAG_SOURCE" ]]; then
            local filtered=()
            for idx in "${matches[@]}"; do
                if [[ "${SW_SOURCES[$idx]}" == "$FLAG_SOURCE" ]]; then
                    filtered+=("$idx")
                fi
            done
            matches=("${filtered[@]}")
        fi

        if [[ ${#matches[@]} -eq 0 ]]; then
            err "No match for '$FLAG_REMOVE' with source '$FLAG_SOURCE'."
            return 1
        fi

        # Remove first match (or only match)
        remove_single "${matches[0]}" "$FLAG_REMOVE"
        return
    fi

    # Interactive mode
    echo ""
    echo -e "${BOLD}REMOVAL OPTIONS:${NC}"
    echo -e "  • Enter a name (e.g., ${CYAN}torch_fix${NC})"
    echo -e "  • Comma-separated for batch (e.g., ${CYAN}torch_fix,yt-dlp${NC})"
    echo -e "  • Press Enter to skip"
    echo ""
    read -p "Remove: " </dev/tty target

    [[ -z "$target" ]] && echo "Skipped." && return

    # Check for batch (comma-separated)
    if [[ "$target" == *","* ]]; then
        IFS=',' read -ra targets <<< "$target"
        for t in "${targets[@]}"; do
            t=$(echo "$t" | xargs)  # trim whitespace
            [[ -z "$t" ]] && continue
            echo ""
            echo -e "${BOLD}━━━ Processing: $t ━━━${NC}"
            process_single_removal "$t"
        done
    else
        process_single_removal "$target"
    fi
}

process_single_removal() {
    local target="$1"
    local matches
    matches=($(find_matches "$target"))

    if [[ ${#matches[@]} -eq 0 ]]; then
        err "Software '$target' not found in audit results."
        return 1
    fi

    local found=-1

    if [[ ${#matches[@]} -gt 1 ]]; then
        echo ""
        echo -e "${YELLOW}Multiple matches for '$target':${NC}"
        echo ""
        for ((j=0; j<${#matches[@]}; j++)); do
            local idx="${matches[$j]}"
            printf "  ${CYAN}%d)${NC} %-25s %-10s %-35s %s\n" \
                $((j+1)) \
                "${SW_NAMES[$idx]}" \
                "${SW_SOURCES[$idx]}" \
                "${SW_LOCATIONS[$idx]}" \
                "${SW_SIZES[$idx]}"
        done
        echo ""
        read -p "Select (1-${#matches[@]}): " </dev/tty selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#matches[@]} ]]; then
            found="${matches[$((selection-1))]}"
        else
            err "Invalid selection."
            return 1
        fi
    else
        found="${matches[0]}"
    fi

    remove_single "$found" "$target"
}

# ============================================================
# MODULE 10 — INTERACTIVE TUI (fzf/dialog)
# ============================================================

interactive_tui() {
    # Check for fzf
    if command -v fzf &>/dev/null; then
        tui_fzf
    elif command -v dialog &>/dev/null; then
        tui_dialog
    else
        # Fallback to standard display + prompt
        display_results
        remove_software
    fi
}

tui_fzf() {
    local count=${#SW_NAMES[@]}
    local tmpfile
    tmpfile=$(mktemp)

    # Build fzf input
    for ((i=0; i<count; i++)); do
        printf "%d|%-30s|%-10s|%-35s|%10s|%8s\n" \
            "$i" "${SW_NAMES[$i]}" "${SW_SOURCES[$i]}" "${SW_LOCATIONS[$i]}" "${SW_SIZES[$i]}" "${SW_LAST_USED[$i]}" >> "$tmpfile"
    done

    # Sort by size (field 5 after splitting)
    local selected
    selected=$(sort -t'|' -k5 -h -r "$tmpfile" | \
        fzf --multi --header="Select software to remove (TAB to multi-select, ENTER to confirm)" \
            --preview="echo {}" \
            --delimiter='|' \
            --with-nth=2,3,4,5,6)

    rm -f "$tmpfile"

    if [[ -z "$selected" ]]; then
        echo "No selection made."
        return
    fi

    # Process selections
    while IFS= read -r line; do
        local idx
        idx=$(echo "$line" | cut -d'|' -f1)
        remove_single "$idx" "${SW_NAMES[$idx]}"
    done <<< "$selected"
}

tui_dialog() {
    local count=${#SW_NAMES[@]}
    local -a items=()

    for ((i=0; i<count; i++)); do
        items+=("${SW_NAMES[$i]}" "${SW_SOURCES[$i]} | ${SW_SIZES[$i]}" "off")
    done

    local selected
    selected=$(dialog --checklist "Software Audit - Select to Remove" 30 80 20 "${items[@]}" 2>&1 >/dev/tty)

    clear

    if [[ -z "$selected" ]]; then
        echo "No selection made."
        return
    fi

    for name in $selected; do
        name=$(echo "$name" | tr -d '"')
        process_single_removal "$name"
    done
}


# ============================================================
# MAIN EXECUTION
# ============================================================

main() {
    parse_args "$@"
    setup_colors

    # Help
    if [[ "$FLAG_HELP" -eq 1 ]]; then
        show_help
    fi

    # Restore mode
    if [[ "$FLAG_RESTORE" -eq 1 ]]; then
        restore_from_backup
        exit 0
    fi

    # Banner
    if [[ "$FLAG_QUIET" -eq 0 ]]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║     SOFTWARE AUDIT & REMOVAL ENGINE v${VERSION}                  ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
    fi

    # Load data (cache or scan)
    if [[ "$FLAG_REFRESH" -eq 0 ]] && load_cache; then
        : # Loaded from cache
    else
        msg "${CYAN}[*] Running full scan (parallel)...${NC}"
        run_parallel_scan
        save_cache
        msg "${GREEN}[✓] Scan complete. Results cached.${NC}"
    fi

    # Detect duplicates
    detect_duplicates

    # Orphan scan mode
    if [[ "$FLAG_ORPHANS" -eq 1 ]]; then
        scan_orphans
        exit 0
    fi

    # Export mode
    if [[ -n "$FLAG_EXPORT" ]]; then
        export_results "$FLAG_EXPORT"
        # Still show results unless quiet
        if [[ "$FLAG_QUIET" -eq 1 ]]; then
            exit 0
        fi
    fi

    # Display results
    display_results

    # Non-interactive removal
    if [[ -n "$FLAG_REMOVE" ]]; then
        remove_software
        exit 0
    fi

    # Interactive mode (skip in quiet mode)
    if [[ "$FLAG_QUIET" -eq 0 ]]; then
        # Use TUI if available, otherwise standard prompt
        if [[ -t 0 ]]; then
            remove_software
        fi
    fi
}

main "$@"
