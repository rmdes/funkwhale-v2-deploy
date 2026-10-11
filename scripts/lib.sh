#!/bin/bash
#
# Shared helpers for upgrade.sh and migrate-v1-to-v2.sh.
# Sourced, not executed. Both scripts run as root on the Funkwhale host.
#
# Paths can be overridden from the environment, e.g. FUNKWHALE_DIR=/opt/funkwhale.
#

FUNKWHALE_DIR="${FUNKWHALE_DIR:-/srv/funkwhale}"
BACKUP_BASE="${BACKUP_BASE:-$FUNKWHALE_DIR/backups}"
ROLLBACK_MARKER="$BACKUP_BASE/.rollback_info"
VERSION_MARKER="$FUNKWHALE_DIR/.installed_version"
STAGING_DIR="$FUNKWHALE_DIR/.upgrade-staging"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
DB_NAME="${DB_NAME:-funkwhale}"
DB_USER="${DB_USER:-funkwhale}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
ARTIFACTS_URL="${ARTIFACTS_URL:-https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts}"

# Config templates shipped in this repo (config/systemd, config/nginx)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKUP_DIR=""
NGINX_SITE_CONFIG=""  # set by detect_nginx_config
CHANGES_STARTED=false # set once the live install has been modified

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_services_stopped() {
    if systemctl is-active --quiet funkwhale-server.service; then
        log_error "Funkwhale services are still running. Stop them first:"
        log_error "  systemctl stop funkwhale.target"
        exit 1
    fi
}

# Print a value from the Funkwhale .env file
env_value() {
    sed -n "s/^$1=//p" "$FUNKWHALE_DIR/config/.env" 2>/dev/null | tail -n 1
}

# pip reports 2.0.0rc15, release tags are 2.0.0-rc15
normalize_version() {
    sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)(a|b|rc)([0-9]+)$/\1-\2\3/'
}

detect_installed_version() {
    local version=""
    if [[ -s "$VERSION_MARKER" ]]; then
        version=$(cat "$VERSION_MARKER")
    elif [[ -x "$FUNKWHALE_DIR/venv/bin/pip" ]]; then
        version=$("$FUNKWHALE_DIR/venv/bin/pip" show funkwhale-api 2>/dev/null | awk '/^Version:/ {print $2}' | normalize_version)
    elif [[ -x "$FUNKWHALE_DIR/virtualenv/bin/pip" ]]; then
        version=$("$FUNKWHALE_DIR/virtualenv/bin/pip" show funkwhale-api 2>/dev/null | awk '/^Version:/ {print $2}' | normalize_version)
    fi
    echo "${version:-unknown}"
}

detect_nginx_config() {
    # Auto-detect the nginx site config for this Funkwhale instance
    local hostname
    hostname=$(env_value FUNKWHALE_HOSTNAME)

    for path in \
        "$NGINX_DIR/sites-enabled/${hostname}.conf" \
        "$NGINX_DIR/sites-enabled/funkwhale.conf" \
        "$NGINX_DIR/sites-available/${hostname}.conf" \
        "$NGINX_DIR/sites-available/funkwhale.conf"; do
        if [[ -f "$path" ]]; then
            # sites-enabled entries are usually symlinks; back up the real file
            NGINX_SITE_CONFIG=$(readlink -f "$path")
            return
        fi
    done

    log_warn "Could not auto-detect nginx site config. Skipping nginx site backup."
}

# Download a release into $STAGING_DIR and verify it, without touching the live install.
fetch_release() {
    local version="$1" part
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"

    for part in api front; do
        log_info "Downloading $part $version..."
        if ! curl -fL --retry 3 -o "$STAGING_DIR/$part.zip" \
            "$ARTIFACTS_URL/$version/download?job=build_$part"; then
            log_error "Download of $part $version failed. Nothing was changed."
            rm -rf "$STAGING_DIR"
            exit 1
        fi
        if ! unzip -tq "$STAGING_DIR/$part.zip" >/dev/null 2>&1; then
            log_error "Downloaded $part archive is not a valid zip. Nothing was changed."
            rm -rf "$STAGING_DIR"
            exit 1
        fi
        unzip -q "$STAGING_DIR/$part.zip" -d "$STAGING_DIR/$part-extracted"
        if [[ ! -d "$STAGING_DIR/$part-extracted/$part" ]]; then
            log_error "The $part archive has no $part/ directory. Nothing was changed."
            rm -rf "$STAGING_DIR"
            exit 1
        fi
        rm "$STAGING_DIR/$part.zip"
    done

    check_python_version "$STAGING_DIR/api-extracted/api/pyproject.toml"

    log_info "Release $version downloaded and verified"
}

# Fail before touching anything if python3 is older than the release requires.
# pyproject.toml declares e.g.  python = "^3.12, <3.15"
check_python_version() {
    local required have
    required=$(sed -nE 's/^python *= *"[\^>=~ ]*([0-9]+\.[0-9]+).*/\1/p' "$1" 2>/dev/null | head -n 1)
    [[ -n "$required" ]] || return 0
    have=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    if [[ "$(printf '%s\n' "$required" "$have" | sort -V | head -n 1)" != "$required" ]]; then
        log_error "This release needs Python >= $required, but python3 is $have. Nothing was changed."
        log_error "Upgrade the OS (Debian 13 / Ubuntu 24.04) or use the Docker deployment."
        rm -rf "$STAGING_DIR"
        exit 1
    fi
}

backup_database() {
    log_info "Backing up PostgreSQL database $DB_NAME..."
    # The redirect runs as root on purpose: postgres can't write into the backup dir
    # shellcheck disable=SC2024
    if ! sudo -u postgres pg_dump -Fc "$DB_NAME" > "$BACKUP_DIR/database.dump" \
        || [[ ! -s "$BACKUP_DIR/database.dump" ]]; then
        log_error "Database backup failed. Nothing was changed."
        exit 1
    fi
    log_info "Database backup: $(du -h "$BACKUP_DIR/database.dump" | cut -f1)"
}

backup_current() {
    local with_db="$1" new_version="$2"
    BACKUP_DIR="$BACKUP_BASE/upgrade-$(date +%Y%m%d_%H%M%S)"

    log_info "Creating backup in $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"

    if [[ "$with_db" == "true" ]]; then
        backup_database
    fi

    log_info "Backing up API..."
    cp -a "$FUNKWHALE_DIR/api" "$BACKUP_DIR/api"

    log_info "Backing up frontend..."
    cp -a "$FUNKWHALE_DIR/front" "$BACKUP_DIR/front"

    # Back up whichever venv style exists
    if [[ -d "$FUNKWHALE_DIR/venv" ]]; then
        log_info "Backing up venv..."
        cp -a "$FUNKWHALE_DIR/venv" "$BACKUP_DIR/venv"
    elif [[ -d "$FUNKWHALE_DIR/virtualenv" ]]; then
        log_info "Backing up virtualenv..."
        cp -a "$FUNKWHALE_DIR/virtualenv" "$BACKUP_DIR/virtualenv"
    fi

    log_info "Backing up config..."
    cp -a "$FUNKWHALE_DIR/config" "$BACKUP_DIR/config"

    log_info "Backing up systemd units..."
    mkdir -p "$BACKUP_DIR/systemd"
    cp "$SYSTEMD_DIR"/funkwhale*.service "$BACKUP_DIR/systemd/" 2>/dev/null || true
    cp "$SYSTEMD_DIR/funkwhale.target" "$BACKUP_DIR/systemd/" 2>/dev/null || true

    # Keep full paths so rollback puts each file back exactly where it came from
    log_info "Backing up nginx config..."
    local f
    for f in "$NGINX_SITE_CONFIG" "$NGINX_DIR/funkwhale_proxy.conf"; do
        if [[ -n "$f" && -f "$f" ]]; then
            mkdir -p "$BACKUP_DIR/nginx-files"
            cp -a --parents "$f" "$BACKUP_DIR/nginx-files/"
        fi
    done

    # Save rollback info
    cat > "$ROLLBACK_MARKER" <<EOF
$BACKUP_DIR
BACKUP_DATE=$(date)
OLD_VERSION=$(detect_installed_version)
NEW_VERSION=$new_version
WITH_DB=$with_db
EOF

    log_info "Backup complete: $BACKUP_DIR"
    prune_backups
}

# Keep only the newest $KEEP_BACKUPS upgrade backups (names sort by date)
prune_backups() {
    local old
    (( KEEP_BACKUPS >= 1 )) || return 0
    printf '%s\n' "$BACKUP_BASE"/upgrade-* | sort -r | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
        if [[ -d "$old" ]]; then
            log_info "Removing old backup $old"
            rm -rf "$old"
        fi
    done
}

# Print a rollback hint if we exit with an error after modifying the live install.
# Installed as an EXIT trap by the upgrade commands.
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 && "$CHANGES_STARTED" == "true" ]]; then
        log_error "Upgrade failed partway through. Restore the previous version with:"
        log_error "  sudo bash $0 rollback"
    fi
    rm -rf "$STAGING_DIR"
    return $rc
}

# Install the OS packages the release needs, as the upstream upgrade guide does
install_os_dependencies() {
    if [[ -f "$FUNKWHALE_DIR/api/install_os_dependencies.sh" ]]; then
        log_info "Installing OS dependencies..."
        bash "$FUNKWHALE_DIR/api/install_os_dependencies.sh" install
    else
        log_warn "api/install_os_dependencies.sh not found in this release; skipping OS dependencies"
    fi
}

# Swap the staged release into place and rebuild the Python environment
install_release() {
    log_info "Installing new API and frontend..."
    CHANGES_STARTED=true
    rm -rf "$FUNKWHALE_DIR/api" "$FUNKWHALE_DIR/front"
    mv "$STAGING_DIR/api-extracted/api" "$FUNKWHALE_DIR/api"
    mv "$STAGING_DIR/front-extracted/front" "$FUNKWHALE_DIR/front"
    rm -rf "$STAGING_DIR"

    install_os_dependencies

    # Funkwhale v2 uses venv instead of virtualenv
    log_info "Creating new Python virtual environment..."
    rm -rf "$FUNKWHALE_DIR/venv"
    python3 -m venv "$FUNKWHALE_DIR/venv"
    "$FUNKWHALE_DIR/venv/bin/pip" install --upgrade pip wheel

    log_info "Installing Funkwhale API package..."
    "$FUNKWHALE_DIR/venv/bin/pip" install --editable "$FUNKWHALE_DIR/api"

    chown -R funkwhale:funkwhale "$FUNKWHALE_DIR/api" "$FUNKWHALE_DIR/front" "$FUNKWHALE_DIR/venv"

    log_info "Installation complete"
}

# Install the systemd units shipped in this repo (config/systemd)
install_systemd_units() {
    log_info "Updating systemd unit files..."
    local unit
    for unit in funkwhale.target funkwhale-server.service funkwhale-worker.service funkwhale-beat.service; do
        if [[ ! -f "$REPO_DIR/config/systemd/$unit" ]]; then
            log_error "Missing $REPO_DIR/config/systemd/$unit - run this script from a full checkout of the repo"
            exit 1
        fi
        sed "s#/srv/funkwhale#$FUNKWHALE_DIR#g" "$REPO_DIR/config/systemd/$unit" > "$SYSTEMD_DIR/$unit"
    done

    systemctl daemon-reload
    log_info "Systemd units updated"
}

# Install the nginx proxy snippet shipped in this repo (config/nginx)
install_proxy_conf() {
    log_info "Updating nginx proxy configuration..."
    cp "$REPO_DIR/config/nginx/funkwhale_proxy.conf" "$NGINX_DIR/funkwhale_proxy.conf"

    if nginx -t; then
        log_info "Nginx configuration valid"
    else
        log_error "Nginx configuration test failed (see output above)"
        exit 1
    fi
}

run_migrations() {
    # Run from api/, the same working directory as the services
    cd "$FUNKWHALE_DIR/api" || exit 1

    log_info "Collecting static files..."
    sudo -u funkwhale "$FUNKWHALE_DIR/venv/bin/funkwhale-manage" collectstatic --no-input

    log_info "Applying database migrations..."
    sudo -u funkwhale "$FUNKWHALE_DIR/venv/bin/funkwhale-manage" migrate

    log_info "Migrations complete"
}

start_services() {
    log_info "Starting Funkwhale services..."
    systemctl start funkwhale.target
    systemctl reload nginx

    sleep 5

    if systemctl is-active --quiet funkwhale-server.service; then
        log_info "Funkwhale services started successfully!"
    else
        log_error "Services failed to start. Check logs with:"
        log_error "  journalctl -u funkwhale-server.service"
        exit 1
    fi
}

record_installed_version() {
    echo "$1" > "$VERSION_MARKER"
    chown funkwhale:funkwhale "$VERSION_MARKER"
}

restore_nginx_files() {
    local f

    if [[ -d "$BACKUP_DIR/nginx-files" ]]; then
        log_info "Restoring nginx config..."
        (cd "$BACKUP_DIR/nginx-files" && find . -type f) | while read -r f; do
            cp -a "$BACKUP_DIR/nginx-files/${f#./}" "/${f#./}"
        done
    elif [[ -d "$BACKUP_DIR/nginx" ]]; then
        # Backups made by older versions of these scripts: flat copies.
        # Only overwrite site files that still exist; never add new ones to sites-enabled.
        log_info "Restoring nginx config (legacy backup)..."
        for f in "$BACKUP_DIR/nginx/"*; do
            [[ -f "$f" ]] || continue
            if [[ "$(basename "$f")" == "funkwhale_proxy.conf" ]]; then
                cp "$f" "$NGINX_DIR/funkwhale_proxy.conf"
            elif [[ -e "$NGINX_DIR/sites-enabled/$(basename "$f")" ]]; then
                cp "$f" "$(readlink -f "$NGINX_DIR/sites-enabled/$(basename "$f")")"
            fi
        done
    fi
}

restore_database() {
    if [[ -f "$BACKUP_DIR/database.dump" ]]; then
        log_warn "Database backup found: $BACKUP_DIR/database.dump"
        read -p "Restore database? This will OVERWRITE current data! [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Recreate the database rather than pg_restore --clean: objects added by the
            # newer migrations aren't in the dump and would block dropping the old ones
            log_info "Restoring PostgreSQL database..."
            sudo -u postgres dropdb --force "$DB_NAME"
            sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
            # shellcheck disable=SC2024  # root reads the dump; postgres gets it on stdin
            sudo -u postgres pg_restore -d "$DB_NAME" < "$BACKUP_DIR/database.dump"
            log_info "Database restored"
        else
            log_info "Database NOT restored (kept current data)"
        fi
    elif [[ -f "$BACKUP_DIR/database.sql" ]]; then
        log_warn "This backup has a pg_dumpall file. Restore it manually with:"
        log_warn "  sudo -u postgres dropdb $DB_NAME"
        log_warn "  sudo -u postgres psql -f $BACKUP_DIR/database.sql postgres"
    else
        log_warn "NOTE: This backup has no database dump; the database was NOT rolled back."
    fi
}

do_rollback() {
    log_info "Starting rollback..."

    check_root

    if [[ ! -f "$ROLLBACK_MARKER" ]]; then
        log_error "No rollback information found. Cannot rollback."
        exit 1
    fi

    BACKUP_DIR=$(head -1 "$ROLLBACK_MARKER")

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi

    local old_version
    old_version=$(sed -n 's/^OLD_VERSION=//p' "$ROLLBACK_MARKER")

    log_info "Rolling back from backup: $BACKUP_DIR"

    # Stop services
    systemctl stop funkwhale.target 2>/dev/null || true

    log_info "Restoring API..."
    rm -rf "$FUNKWHALE_DIR/api"
    cp -a "$BACKUP_DIR/api" "$FUNKWHALE_DIR/api"

    log_info "Restoring frontend..."
    rm -rf "$FUNKWHALE_DIR/front"
    cp -a "$BACKUP_DIR/front" "$FUNKWHALE_DIR/front"

    log_info "Restoring virtual environment..."
    rm -rf "$FUNKWHALE_DIR/venv" "$FUNKWHALE_DIR/virtualenv"
    if [[ -d "$BACKUP_DIR/venv" ]]; then
        cp -a "$BACKUP_DIR/venv" "$FUNKWHALE_DIR/venv"
    elif [[ -d "$BACKUP_DIR/virtualenv" ]]; then
        cp -a "$BACKUP_DIR/virtualenv" "$FUNKWHALE_DIR/virtualenv"
    fi

    if [[ -d "$BACKUP_DIR/config" ]]; then
        log_info "Restoring config..."
        rm -rf "$FUNKWHALE_DIR/config"
        cp -a "$BACKUP_DIR/config" "$FUNKWHALE_DIR/config"
    fi

    log_info "Restoring systemd units..."
    cp "$BACKUP_DIR/systemd/"* "$SYSTEMD_DIR/"
    systemctl daemon-reload

    restore_nginx_files
    restore_database

    if [[ -n "$old_version" && "$old_version" != "unknown" ]]; then
        record_installed_version "$old_version"
    else
        rm -f "$VERSION_MARKER"
    fi

    systemctl start funkwhale.target
    if nginx -t; then
        systemctl reload nginx
    else
        log_warn "Restored nginx config does not pass 'nginx -t'; nginx was not reloaded"
    fi

    log_info "=========================================="
    log_info "Rollback complete!"
    log_info "=========================================="
}

show_status() {
    echo "Current Funkwhale installation:"
    echo "================================"

    if [[ -d "$FUNKWHALE_DIR/venv" ]]; then
        echo "Virtual env: venv (v2 style)"
    elif [[ -d "$FUNKWHALE_DIR/virtualenv" ]]; then
        echo "Virtual env: virtualenv (v1 style)"
    fi

    echo "Installed version: $(detect_installed_version)"
    echo ""
    echo "Service status:"
    systemctl status funkwhale.target --no-pager 2>/dev/null || echo "  Not running"

    if [[ -f "$ROLLBACK_MARKER" ]]; then
        echo ""
        echo "Rollback available:"
        cat "$ROLLBACK_MARKER"
    fi
}
