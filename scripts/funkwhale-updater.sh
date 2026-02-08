#!/bin/bash
#
# Funkwhale Updater - Check for new releases and upgrade
#
# Usage:
#   ./funkwhale-updater.sh check                - Check for new versions
#   ./funkwhale-updater.sh upgrade              - Upgrade to latest RC
#   ./funkwhale-updater.sh upgrade --with-db    - Upgrade with database backup
#   ./funkwhale-updater.sh upgrade <version>    - Upgrade to specific version
#   ./funkwhale-updater.sh rollback             - Rollback to previous version
#   ./funkwhale-updater.sh status               - Show current installation
#

set -e

# ============== CONFIGURATION ==============
FUNKWHALE_DIR="/srv/funkwhale"
BACKUP_BASE="/srv/funkwhale/backups"
GITLAB_API="https://dev.funkwhale.audio/api/v4/projects/funkwhale%2Ffunkwhale"
ROLLBACK_MARKER="$BACKUP_BASE/.rollback_info"
VERSION_MARKER="$FUNKWHALE_DIR/.installed_version"

# Set to your server's SSH alias/hostname, or leave empty to run locally
SSH_HOST=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============== HELPER FUNCTIONS ==============

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# Check if running locally or need SSH
run_cmd() {
    if [[ -n "$SSH_HOST" ]]; then
        ssh "$SSH_HOST" "$@"
    else
        eval "$@"
    fi
}

run_cmd_sudo() {
    if [[ -n "$SSH_HOST" ]]; then
        ssh "$SSH_HOST" "sudo $*"
    else
        sudo "$@"
    fi
}

# ============== VERSION FUNCTIONS ==============

get_installed_version() {
    local version
    # First check our version marker file (set after successful upgrade)
    version=$(run_cmd "cat $VERSION_MARKER 2>/dev/null" 2>/dev/null || echo "")

    if [[ -n "$version" ]]; then
        echo "$version"
        return
    fi

    # Fall back to pip version (won't distinguish between RCs)
    version=$(run_cmd "$FUNKWHALE_DIR/venv/bin/pip show funkwhale-api 2>/dev/null | grep '^Version:' | awk '{print \$2}'" 2>/dev/null || echo "unknown")
    echo "$version"
}

get_available_versions() {
    # Fetch tags from GitLab API
    curl -s "${GITLAB_API}/repository/tags?per_page=20" | \
        jq -r '.[].name' 2>/dev/null | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | \
        head -15
}

get_latest_version() {
    # Get the latest RC or stable version
    local filter="${1:-rc}"  # "rc" for release candidates, "stable" for stable only

    if [[ "$filter" == "stable" ]]; then
        curl -s "${GITLAB_API}/repository/tags?per_page=50" | \
            jq -r '.[].name' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | \
            head -1
    else
        curl -s "${GITLAB_API}/repository/tags?per_page=20" | \
            jq -r '.[].name' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | \
            head -1
    fi
}

version_gt() {
    # Compare versions: returns 0 if $1 > $2
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# ============== CHECK COMMAND ==============

do_check() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Funkwhale Version Checker                     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_step "Checking installed version..."
    local installed
    installed=$(get_installed_version)
    echo -e "  Installed: ${CYAN}$installed${NC}"

    log_step "Fetching available versions from GitLab..."
    local latest
    latest=$(get_latest_version)
    local latest_stable
    latest_stable=$(get_latest_version "stable")

    echo ""
    echo -e "  Latest RC:     ${GREEN}$latest${NC}"
    if [[ -n "$latest_stable" ]]; then
        echo -e "  Latest Stable: ${GREEN}$latest_stable${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Available versions:${NC}"
    get_available_versions | while read -r ver; do
        if [[ "$ver" == "$installed" ]]; then
            echo -e "  ${CYAN}► $ver${NC} (installed)"
        else
            echo "    $ver"
        fi
    done

    echo ""

    # Compare versions
    if [[ "$installed" == "unknown" ]]; then
        log_warn "Could not determine installed version"
    elif [[ "$installed" == "$latest" ]]; then
        log_info "You are running the latest version!"
    elif version_gt "$latest" "$installed"; then
        echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  UPDATE AVAILABLE: $installed → $latest${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "  To upgrade, run:"
        echo -e "    ${CYAN}$0 upgrade${NC}           # Upgrade to $latest"
        echo -e "    ${CYAN}$0 upgrade <version>${NC} # Upgrade to specific version"
        echo ""
    fi
}

# ============== BACKUP FUNCTION ==============

do_backup() {
    local version="$1"
    local with_db="${2:-false}"
    local backup_dir="$BACKUP_BASE/upgrade-$(date +%Y%m%d_%H%M%S)"

    log_step "Creating backup in $backup_dir..."

    run_cmd_sudo "mkdir -p $backup_dir"

    # Optional database backup
    if [[ "$with_db" == "true" ]]; then
        log_info "Backing up PostgreSQL database (this may take a moment)..."
        run_cmd_sudo "sudo -u postgres pg_dumpall > $backup_dir/database.sql"
        local db_size
        db_size=$(run_cmd "ls -lh $backup_dir/database.sql | awk '{print \$5}'")
        log_info "Database backup complete: $db_size"
    fi

    log_info "Backing up API..."
    run_cmd_sudo "cp -a $FUNKWHALE_DIR/api $backup_dir/api"

    log_info "Backing up frontend..."
    run_cmd_sudo "cp -a $FUNKWHALE_DIR/front $backup_dir/front"

    log_info "Backing up venv..."
    run_cmd_sudo "cp -a $FUNKWHALE_DIR/venv $backup_dir/venv"

    log_info "Backing up config..."
    run_cmd_sudo "cp -a $FUNKWHALE_DIR/config $backup_dir/config"

    log_info "Backing up systemd units..."
    run_cmd_sudo "mkdir -p $backup_dir/systemd"
    run_cmd_sudo "cp /etc/systemd/system/funkwhale*.service $backup_dir/systemd/ 2>/dev/null || true"
    run_cmd_sudo "cp /etc/systemd/system/funkwhale.target $backup_dir/systemd/ 2>/dev/null || true"

    # Save rollback info
    run_cmd_sudo "bash -c 'echo \"$backup_dir\" > $ROLLBACK_MARKER'"
    run_cmd_sudo "bash -c 'echo \"BACKUP_DATE=$(date)\" >> $ROLLBACK_MARKER'"
    run_cmd_sudo "bash -c 'echo \"OLD_VERSION=$version\" >> $ROLLBACK_MARKER'"
    run_cmd_sudo "bash -c 'echo \"WITH_DB=$with_db\" >> $ROLLBACK_MARKER'"

    log_info "Backup complete: $backup_dir"
    echo "$backup_dir"
}

# ============== UPGRADE COMMAND ==============

do_upgrade() {
    local target_version=""
    local with_db="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-db)
                with_db="true"
                shift
                ;;
            *)
                if [[ -z "$target_version" ]]; then
                    target_version="$1"
                fi
                shift
                ;;
        esac
    done

    # Default to latest if no version specified
    if [[ -z "$target_version" ]]; then
        target_version=$(get_latest_version)
    fi

    local installed
    installed=$(get_installed_version)

    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Funkwhale Upgrader                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "  Current version:  ${CYAN}$installed${NC}"
    echo -e "  Target version:   ${GREEN}$target_version${NC}"
    echo -e "  Database backup:  ${CYAN}$with_db${NC}"
    echo ""

    if [[ "$installed" == "$target_version" ]]; then
        log_info "Already running version $target_version"
        return 0
    fi

    # Confirm upgrade
    echo -e "${YELLOW}This will upgrade Funkwhale from $installed to $target_version${NC}"
    if [[ "$with_db" == "true" ]]; then
        echo -e "${GREEN}PostgreSQL database will be backed up before upgrade${NC}"
    else
        echo -e "${YELLOW}Tip: Use --with-db flag to also backup the database${NC}"
    fi
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Upgrade cancelled"
        return 1
    fi

    # Step 1: Stop services
    log_step "Stopping Funkwhale services..."
    run_cmd_sudo "systemctl stop funkwhale.target" || true
    sleep 2

    # Step 2: Create backup (with optional database)
    log_step "Creating backup..."
    local backup_dir
    backup_dir=$(do_backup "$installed" "$with_db")
    run_cmd_sudo "bash -c 'echo \"NEW_VERSION=$target_version\" >> $ROLLBACK_MARKER'"

    # Step 3: Download new version
    log_step "Downloading Funkwhale $target_version..."

    run_cmd_sudo "bash -c 'cd $FUNKWHALE_DIR && curl -L -o api-$target_version.zip \"https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$target_version/download?job=build_api\"'"
    run_cmd_sudo "bash -c 'cd $FUNKWHALE_DIR && curl -L -o front-$target_version.zip \"https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$target_version/download?job=build_front\"'"

    # Step 4: Extract files
    log_step "Installing new version..."

    # Clean old files
    run_cmd_sudo "rm -rf $FUNKWHALE_DIR/api/*"
    run_cmd_sudo "rm -rf $FUNKWHALE_DIR/front/*"

    # Extract API
    run_cmd_sudo "bash -c 'cd $FUNKWHALE_DIR && unzip -q api-$target_version.zip -d extracted && mv extracted/api/* api/ && rm -rf extracted api-$target_version.zip'"

    # Extract frontend
    run_cmd_sudo "bash -c 'cd $FUNKWHALE_DIR && unzip -q front-$target_version.zip -d extracted && mv extracted/front/* front/ && rm -rf extracted front-$target_version.zip'"

    # Step 5: Update venv
    log_step "Updating Python environment..."
    run_cmd_sudo "rm -rf $FUNKWHALE_DIR/venv"
    run_cmd_sudo "python3 -m venv $FUNKWHALE_DIR/venv"
    run_cmd_sudo "$FUNKWHALE_DIR/venv/bin/pip install --upgrade pip wheel"
    run_cmd_sudo "$FUNKWHALE_DIR/venv/bin/pip install --editable $FUNKWHALE_DIR/api"

    # Step 6: Fix permissions
    log_step "Fixing permissions..."
    run_cmd_sudo "chown -R funkwhale:funkwhale $FUNKWHALE_DIR/api $FUNKWHALE_DIR/front $FUNKWHALE_DIR/venv"

    # Step 7: Run migrations (must run from api directory due to troi library)
    log_step "Running database migrations..."
    run_cmd_sudo "bash -c 'cd $FUNKWHALE_DIR/api && sudo -u funkwhale $FUNKWHALE_DIR/venv/bin/funkwhale-manage collectstatic --no-input'"
    run_cmd_sudo "bash -c 'cd $FUNKWHALE_DIR/api && sudo -u funkwhale $FUNKWHALE_DIR/venv/bin/funkwhale-manage migrate'"

    # Step 8: Start services
    log_step "Starting services..."
    run_cmd_sudo "systemctl daemon-reload"
    run_cmd_sudo "systemctl start funkwhale.target"

    sleep 3

    # Step 9: Verify
    log_step "Verifying upgrade..."
    local new_version
    new_version=$(get_installed_version)

    if run_cmd_sudo "systemctl is-active --quiet funkwhale-server.service"; then
        # Save the installed version to marker file
        run_cmd_sudo "bash -c 'echo \"$target_version\" > $VERSION_MARKER'"
        run_cmd_sudo "chown funkwhale:funkwhale $VERSION_MARKER"

        echo ""
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  UPGRADE SUCCESSFUL!${NC}"
        echo -e "${GREEN}  $installed → $target_version${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "  If something goes wrong, run:"
        echo -e "    ${CYAN}$0 rollback${NC}"
        echo ""
    else
        log_error "Services failed to start!"
        log_warn "Check logs with: ssh $SSH_HOST journalctl -u funkwhale-server -n 50"
        log_warn "To rollback: $0 rollback"
        return 1
    fi
}

# ============== ROLLBACK COMMAND ==============

do_rollback() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Funkwhale Rollback                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Check for rollback info
    if ! run_cmd "test -f $ROLLBACK_MARKER" 2>/dev/null; then
        log_error "No rollback information found"
        return 1
    fi

    local backup_dir
    backup_dir=$(run_cmd "head -1 $ROLLBACK_MARKER")
    local old_version
    old_version=$(run_cmd "grep OLD_VERSION $ROLLBACK_MARKER | cut -d= -f2")

    echo -e "  Backup location: ${CYAN}$backup_dir${NC}"
    echo -e "  Rolling back to: ${YELLOW}$old_version${NC}"
    echo ""

    read -p "Continue with rollback? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Rollback cancelled"
        return 1
    fi

    # Stop services
    log_step "Stopping services..."
    run_cmd_sudo "systemctl stop funkwhale.target" || true

    # Restore files
    log_step "Restoring files from backup..."
    run_cmd_sudo "rm -rf $FUNKWHALE_DIR/api $FUNKWHALE_DIR/front $FUNKWHALE_DIR/venv"
    run_cmd_sudo "cp -a $backup_dir/api $FUNKWHALE_DIR/api"
    run_cmd_sudo "cp -a $backup_dir/front $FUNKWHALE_DIR/front"
    run_cmd_sudo "cp -a $backup_dir/venv $FUNKWHALE_DIR/venv"

    # Restore systemd units
    log_step "Restoring systemd units..."
    run_cmd_sudo "cp $backup_dir/systemd/* /etc/systemd/system/"
    run_cmd_sudo "systemctl daemon-reload"

    # Check if database backup exists and offer to restore
    if run_cmd "test -f $backup_dir/database.sql" 2>/dev/null; then
        echo ""
        log_warn "Database backup found: $backup_dir/database.sql"
        read -p "Restore database? This will OVERWRITE current data! [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_step "Restoring PostgreSQL database..."
            run_cmd_sudo "sudo -u postgres psql < $backup_dir/database.sql"
            log_info "Database restored"
        else
            log_info "Database NOT restored (kept current data)"
        fi
    fi

    # Start services
    log_step "Starting services..."
    run_cmd_sudo "systemctl start funkwhale.target"

    sleep 3

    if run_cmd_sudo "systemctl is-active --quiet funkwhale-server.service"; then
        # Restore version marker
        run_cmd_sudo "bash -c 'echo \"$old_version\" > $VERSION_MARKER'"

        echo ""
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ROLLBACK SUCCESSFUL!${NC}"
        echo -e "${GREEN}  Restored to version: $old_version${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        echo ""
    else
        log_error "Services failed to start after rollback"
        return 1
    fi
}

# ============== STATUS COMMAND ==============

do_status() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Funkwhale Status                              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local installed
    installed=$(get_installed_version)
    echo -e "  Installed version: ${CYAN}$installed${NC}"
    echo ""

    log_step "Service status:"
    run_cmd "systemctl status funkwhale.target --no-pager -l" 2>/dev/null || echo "  Could not get status"

    echo ""
    if run_cmd "test -f $ROLLBACK_MARKER" 2>/dev/null; then
        log_step "Rollback available:"
        run_cmd "cat $ROLLBACK_MARKER" | sed 's/^/  /'
    fi
}

# ============== MAIN ==============

check_dependencies() {
    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

main() {
    check_dependencies

    case "${1:-}" in
        check)
            do_check
            ;;
        upgrade)
            do_upgrade "${2:-}"
            ;;
        rollback)
            do_rollback
            ;;
        status)
            do_status
            ;;
        *)
            echo ""
            echo -e "${BLUE}Funkwhale Updater${NC}"
            echo "================="
            echo ""
            echo "Usage: $0 <command> [options]"
            echo ""
            echo "Commands:"
            echo "  check              Check for available updates"
            echo "  upgrade            Upgrade to latest version"
            echo "  upgrade <version>  Upgrade to specific version (e.g., 2.0.0-rc13)"
            echo "  rollback           Rollback to previous version"
            echo "  status             Show current installation status"
            echo ""
            echo "Options:"
            echo "  --with-db          Also backup PostgreSQL database before upgrade"
            echo ""
            echo "Examples:"
            echo "  $0 check"
            echo "  $0 upgrade                      # Latest version, code backup only"
            echo "  $0 upgrade --with-db            # Latest version + database backup"
            echo "  $0 upgrade 2.0.0-rc13           # Specific version"
            echo "  $0 upgrade 2.0.0-rc13 --with-db # Specific version + database backup"
            echo ""
            ;;
    esac
}

main "$@"
