#!/bin/bash
#
# Funkwhale Updater - Check for new releases and upgrade
#
# Usage:
#   ./funkwhale-updater.sh check                          - Check for new versions
#   ./funkwhale-updater.sh upgrade [<version>] [--with-db] - Upgrade (default: latest)
#   ./funkwhale-updater.sh rollback                       - Rollback to previous version
#   ./funkwhale-updater.sh status                         - Show current installation
#
# Runs on the Funkwhale host itself (with sudo), or from another machine
# over SSH when SSH_HOST is set.
#

set -e

# ============== CONFIGURATION ==============
FUNKWHALE_DIR="${FUNKWHALE_DIR:-/srv/funkwhale}"
BACKUP_BASE="$FUNKWHALE_DIR/backups"
GITLAB_API="${GITLAB_API:-https://dev.funkwhale.audio/api/v4/projects/funkwhale%2Ffunkwhale}"
ARTIFACTS_URL="${ARTIFACTS_URL:-https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts}"
ROLLBACK_MARKER="$BACKUP_BASE/.rollback_info"
VERSION_MARKER="$FUNKWHALE_DIR/.installed_version"
STAGING_DIR="$FUNKWHALE_DIR/.upgrade-staging"
DB_NAME="${DB_NAME:-funkwhale}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"

# Set to your server's SSH alias/hostname, or leave empty to run locally
SSH_HOST="${SSH_HOST:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

BACKUP_DIR=""
CHANGES_STARTED=false

# ============== HELPER FUNCTIONS ==============

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# Run a shell snippet on the Funkwhale host: locally, or over SSH.
# Snippets are built locally, so client-side expansion is intended.
# shellcheck disable=SC2029
run_cmd() {
    if [[ -n "$SSH_HOST" ]]; then
        ssh "$SSH_HOST" "$1"
    else
        bash -c "$1"
    fi
}

# Run a shell snippet as root. The whole snippet, redirects included, runs under root's shell.
# shellcheck disable=SC2029
run_cmd_sudo() {
    if [[ -n "$SSH_HOST" ]]; then
        ssh "$SSH_HOST" "sudo bash -c $(printf '%q' "$1")"
    else
        sudo bash -c "$1"
    fi
}

journal_hint() {
    echo "${SSH_HOST:+ssh $SSH_HOST }sudo journalctl -u funkwhale-server -n 50"
}

# ============== VERSION FUNCTIONS ==============

# pip reports 2.0.0rc15, release tags are 2.0.0-rc15
normalize_version() {
    sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)(a|b|rc)([0-9]+)$/\1-\2\3/'
}

get_installed_version() {
    local version
    # First check our version marker file (set after successful upgrade)
    version=$(run_cmd "cat $VERSION_MARKER 2>/dev/null" 2>/dev/null || true)

    if [[ -n "$version" ]]; then
        echo "$version"
        return
    fi

    # Fall back to pip version
    version=$(run_cmd "$FUNKWHALE_DIR/venv/bin/pip show funkwhale-api 2>/dev/null | awk '/^Version:/ {print \$2}'" 2>/dev/null || true)
    echo "${version:-unknown}" | normalize_version
}

# Print release tags (X.Y.Z and X.Y.Z-suffix) from GitLab, one per line
fetch_tags() {
    local json
    json=$(curl -fsS --max-time 30 "${GITLAB_API}/repository/tags?per_page=100") || return 1
    jq -r '.[].name' <<<"$json" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || true
}

# Sort versions ascending; a pre-release (2.0.0-rc15) sorts below its release (2.0.0)
sort_versions() {
    sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)$/\1.1 \1/; s/^([0-9]+\.[0-9]+\.[0-9]+)-(.+)$/\1.0-\2 \1-\2/' |
        sort -k1,1V | cut -d' ' -f2
}

version_gt() {
    # Returns 0 if $1 > $2
    [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort_versions | tail -n 1)" == "$1" ]]
}

load_tags() {
    if ! TAGS=$(fetch_tags) || [[ -z "$TAGS" ]]; then
        log_error "Could not fetch release tags from $GITLAB_API"
        exit 1
    fi
}

latest_version() {
    sort_versions <<<"$TAGS" | tail -n 1
}

latest_stable_version() {
    grep -v -- - <<<"$TAGS" | sort_versions | tail -n 1
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
    load_tags
    local latest latest_stable
    latest=$(latest_version)
    latest_stable=$(latest_stable_version)

    echo ""
    echo -e "  Latest:        ${GREEN}$latest${NC}"
    if [[ -n "$latest_stable" ]]; then
        echo -e "  Latest Stable: ${GREEN}$latest_stable${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Available versions:${NC}"
    sort_versions <<<"$TAGS" | tail -n 15 | tac | while read -r ver; do
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
    else
        log_info "Installed version $installed is newer than the latest tag $latest"
    fi
}

# ============== UPGRADE STEPS ==============

# Download a release into the staging dir and verify it, without touching the live install
fetch_release() {
    local version="$1" part
    run_cmd_sudo "rm -rf $STAGING_DIR && mkdir -p $STAGING_DIR"

    for part in api front; do
        log_info "Downloading $part $version..."
        if ! run_cmd_sudo "curl -fL --retry 3 -o $STAGING_DIR/$part.zip '$ARTIFACTS_URL/$version/download?job=build_$part' \
                && unzip -tq $STAGING_DIR/$part.zip >/dev/null \
                && unzip -q $STAGING_DIR/$part.zip -d $STAGING_DIR/$part-extracted \
                && test -d $STAGING_DIR/$part-extracted/$part \
                && rm $STAGING_DIR/$part.zip"; then
            log_error "Download or verification of $part $version failed. Nothing was changed."
            run_cmd_sudo "rm -rf $STAGING_DIR"
            return 1
        fi
    done

    log_info "Release $version downloaded and verified"
}

# Sets BACKUP_DIR. Returns non-zero on any failure.
do_backup() {
    local version="$1"
    local with_db="${2:-false}"
    BACKUP_DIR="$BACKUP_BASE/upgrade-$(date +%Y%m%d_%H%M%S)"

    log_step "Creating backup in $BACKUP_DIR..."

    run_cmd_sudo "mkdir -p $BACKUP_DIR" || return 1

    # Optional database backup
    if [[ "$with_db" == "true" ]]; then
        log_info "Backing up PostgreSQL database $DB_NAME (this may take a moment)..."
        run_cmd_sudo "sudo -u postgres pg_dump -Fc $DB_NAME > $BACKUP_DIR/database.dump && test -s $BACKUP_DIR/database.dump" || return 1
        log_info "Database backup complete: $(run_cmd_sudo "du -h $BACKUP_DIR/database.dump | cut -f1")"
    fi

    log_info "Backing up API, frontend, venv and config..."
    run_cmd_sudo "cp -a $FUNKWHALE_DIR/api $FUNKWHALE_DIR/front $FUNKWHALE_DIR/venv $FUNKWHALE_DIR/config $BACKUP_DIR/" || return 1

    log_info "Backing up systemd units..."
    run_cmd_sudo "mkdir -p $BACKUP_DIR/systemd && cp /etc/systemd/system/funkwhale*.service /etc/systemd/system/funkwhale.target $BACKUP_DIR/systemd/" || return 1

    # Save rollback info
    run_cmd_sudo "printf '%s\n' '$BACKUP_DIR' 'BACKUP_DATE=$(date)' 'OLD_VERSION=$version' 'WITH_DB=$with_db' > $ROLLBACK_MARKER" || return 1

    log_info "Backup complete: $BACKUP_DIR"
}

# Keep only the newest $KEEP_BACKUPS upgrade backups (names sort by date)
prune_backups() {
    (( KEEP_BACKUPS >= 1 )) || return 0
    run_cmd_sudo "ls -1d $BACKUP_BASE/upgrade-* 2>/dev/null | sort -r | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -rf"
}

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 && "$CHANGES_STARTED" == "true" ]]; then
        log_error "Upgrade failed partway through. Restore the previous version with:"
        log_error "  $0 rollback"
        log_warn "Logs: $(journal_hint)"
    fi
    return $rc
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
                ;;
            -*)
                log_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -n "$target_version" ]]; then
                    log_error "Unexpected argument: $1"
                    return 1
                fi
                target_version="$1"
                ;;
        esac
        shift
    done

    # Default to latest if no version specified
    if [[ -z "$target_version" ]]; then
        load_tags
        target_version=$(latest_version)
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

    trap on_exit EXIT

    # Step 1: Download and verify while the old version keeps running
    log_step "Downloading Funkwhale $target_version..."
    fetch_release "$target_version"

    # Step 2: Stop services
    log_step "Stopping Funkwhale services..."
    run_cmd_sudo "systemctl stop funkwhale.target" || true
    sleep 2

    # Step 3: Create backup (with optional database)
    log_step "Creating backup..."
    if ! do_backup "$installed" "$with_db"; then
        log_error "Backup failed. Nothing was changed; restarting services."
        run_cmd_sudo "rm -rf $STAGING_DIR"
        run_cmd_sudo "systemctl start funkwhale.target"
        return 1
    fi
    run_cmd_sudo "echo 'NEW_VERSION=$target_version' >> $ROLLBACK_MARKER"
    prune_backups

    # Step 4: Swap in the new release
    log_step "Installing new version..."
    CHANGES_STARTED=true
    run_cmd_sudo "rm -rf $FUNKWHALE_DIR/api $FUNKWHALE_DIR/front \
        && mv $STAGING_DIR/api-extracted/api $FUNKWHALE_DIR/api \
        && mv $STAGING_DIR/front-extracted/front $FUNKWHALE_DIR/front \
        && rm -rf $STAGING_DIR"

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
    run_cmd_sudo "cd $FUNKWHALE_DIR/api && sudo -u funkwhale $FUNKWHALE_DIR/venv/bin/funkwhale-manage collectstatic --no-input"
    run_cmd_sudo "cd $FUNKWHALE_DIR/api && sudo -u funkwhale $FUNKWHALE_DIR/venv/bin/funkwhale-manage migrate"

    # Step 8: Start services
    log_step "Starting services..."
    run_cmd_sudo "systemctl daemon-reload"
    run_cmd_sudo "systemctl start funkwhale.target"

    sleep 3

    # Step 9: Verify
    log_step "Verifying upgrade..."
    if run_cmd_sudo "systemctl is-active --quiet funkwhale-server.service"; then
        # Save the installed version to marker file
        run_cmd_sudo "echo '$target_version' > $VERSION_MARKER && chown funkwhale:funkwhale $VERSION_MARKER"

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
    old_version=$(run_cmd "sed -n 's/^OLD_VERSION=//p' $ROLLBACK_MARKER")

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

    # Restore files (backups made by migrate-v1-to-v2.sh hold a v1 virtualenv instead of venv)
    log_step "Restoring files from backup..."
    run_cmd_sudo "rm -rf $FUNKWHALE_DIR/api $FUNKWHALE_DIR/front $FUNKWHALE_DIR/venv $FUNKWHALE_DIR/virtualenv"
    run_cmd_sudo "cp -a $backup_dir/api $FUNKWHALE_DIR/api"
    run_cmd_sudo "cp -a $backup_dir/front $FUNKWHALE_DIR/front"
    run_cmd_sudo "if [ -d $backup_dir/venv ]; then cp -a $backup_dir/venv $FUNKWHALE_DIR/venv; else cp -a $backup_dir/virtualenv $FUNKWHALE_DIR/virtualenv; fi"
    if run_cmd "test -d $backup_dir/config"; then
        run_cmd_sudo "rm -rf $FUNKWHALE_DIR/config && cp -a $backup_dir/config $FUNKWHALE_DIR/config"
    fi

    # Restore systemd units
    log_step "Restoring systemd units..."
    run_cmd_sudo "cp $backup_dir/systemd/* /etc/systemd/system/"
    run_cmd_sudo "systemctl daemon-reload"

    # Backups made by upgrade.sh also hold nginx files, stored under their full paths
    if run_cmd "test -d $backup_dir/nginx-files"; then
        log_step "Restoring nginx config..."
        run_cmd_sudo "cd $backup_dir/nginx-files && find . -type f | while read -r f; do cp -a \"\$f\" \"/\${f#./}\"; done"
        run_cmd_sudo "nginx -t && systemctl reload nginx" || log_warn "Restored nginx config failed 'nginx -t'; nginx was not reloaded"
    fi

    # Check if database backup exists and offer to restore
    if run_cmd "test -f $backup_dir/database.dump" 2>/dev/null; then
        echo ""
        log_warn "Database backup found: $backup_dir/database.dump"
        read -p "Restore database? This will OVERWRITE current data! [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_step "Restoring PostgreSQL database..."
            run_cmd_sudo "sudo -u postgres pg_restore --clean --if-exists -d $DB_NAME < $backup_dir/database.dump"
            log_info "Database restored"
        else
            log_info "Database NOT restored (kept current data)"
        fi
    elif run_cmd "test -f $backup_dir/database.sql" 2>/dev/null; then
        # Backups made by older versions of this script used pg_dumpall
        log_warn "This backup has a pg_dumpall file. Restore it manually (services stopped) with:"
        log_warn "  sudo -u postgres dropdb $DB_NAME"
        log_warn "  sudo -u postgres psql -f $backup_dir/database.sql postgres"
    fi

    # Start services
    log_step "Starting services..."
    run_cmd_sudo "systemctl start funkwhale.target"

    sleep 3

    if run_cmd_sudo "systemctl is-active --quiet funkwhale-server.service"; then
        # Restore version marker
        if [[ -n "$old_version" && "$old_version" != "unknown" ]]; then
            run_cmd_sudo "echo '$old_version' > $VERSION_MARKER"
        else
            run_cmd_sudo "rm -f $VERSION_MARKER"
        fi

        echo ""
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ROLLBACK SUCCESSFUL!${NC}"
        echo -e "${GREEN}  Restored to version: $old_version${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        echo ""
    else
        log_error "Services failed to start after rollback"
        log_warn "Logs: $(journal_hint)"
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
            shift
            do_upgrade "$@"
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
            echo "Environment:"
            echo "  SSH_HOST           Run against this host over SSH instead of locally"
            echo ""
            echo "Examples:"
            echo "  $0 check"
            echo "  $0 upgrade                      # Latest version, code backup only"
            echo "  $0 upgrade --with-db            # Latest version + database backup"
            echo "  $0 upgrade 2.0.0-rc13           # Specific version"
            echo "  $0 upgrade 2.0.0-rc13 --with-db # Specific version + database backup"
            echo "  SSH_HOST=myserver $0 check      # Remote server"
            echo ""
            ;;
    esac
}

main "$@"
