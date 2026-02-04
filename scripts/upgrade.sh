#!/bin/bash
#
# Funkwhale v2 Upgrade Script
# Upgrades between Funkwhale v2 releases with rollback capability.
#
# Usage:
#   ./upgrade.sh upgrade <version>    e.g. ./upgrade.sh upgrade 2.0.0-rc15
#   ./upgrade.sh rollback
#   ./upgrade.sh status
#

set -e

# Configuration - adjust these paths if your install differs
FUNKWHALE_DIR="/srv/funkwhale"
BACKUP_BASE="$FUNKWHALE_DIR/backups"
BACKUP_DIR="$BACKUP_BASE/upgrade-$(date +%Y%m%d_%H%M%S)"
ROLLBACK_MARKER="$BACKUP_BASE/.rollback_info"
NGINX_SITE_CONFIG=""  # auto-detected below

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

detect_nginx_config() {
    # Auto-detect the nginx site config for this Funkwhale instance
    local hostname
    hostname=$(grep '^FUNKWHALE_HOSTNAME=' "$FUNKWHALE_DIR/config/.env" | cut -d= -f2)

    for path in \
        "/etc/nginx/sites-enabled/${hostname}.conf" \
        "/etc/nginx/sites-enabled/funkwhale.conf" \
        "/etc/nginx/sites-available/${hostname}.conf" \
        "/etc/nginx/sites-available/funkwhale.conf"; do
        if [[ -f "$path" ]]; then
            NGINX_SITE_CONFIG="$path"
            return
        fi
    done

    log_warn "Could not auto-detect nginx site config. Skipping nginx backup/update."
}

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

backup_current() {
    log_info "Creating backup in $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"

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
    cp /etc/systemd/system/funkwhale*.service "$BACKUP_DIR/systemd/" 2>/dev/null || true
    cp /etc/systemd/system/funkwhale.target "$BACKUP_DIR/systemd/" 2>/dev/null || true

    if [[ -n "$NGINX_SITE_CONFIG" ]]; then
        log_info "Backing up nginx config..."
        mkdir -p "$BACKUP_DIR/nginx"
        cp "$NGINX_SITE_CONFIG" "$BACKUP_DIR/nginx/" 2>/dev/null || true
        cp /etc/nginx/funkwhale_proxy.conf "$BACKUP_DIR/nginx/" 2>/dev/null || true
    fi

    # Detect current version
    local old_version="unknown"
    if [[ -d "$FUNKWHALE_DIR/venv" ]]; then
        old_version=$("$FUNKWHALE_DIR/venv/bin/pip" show funkwhale-api 2>/dev/null | grep Version | awk '{print $2}')
    elif [[ -d "$FUNKWHALE_DIR/virtualenv" ]]; then
        old_version=$("$FUNKWHALE_DIR/virtualenv/bin/pip" show funkwhale-api 2>/dev/null | grep Version | awk '{print $2}')
    fi

    # Save rollback info
    cat > "$ROLLBACK_MARKER" <<EOF
$BACKUP_DIR
BACKUP_DATE=$(date)
OLD_VERSION=$old_version
NEW_VERSION=$FUNKWHALE_VERSION
EOF

    log_info "Backup complete: $BACKUP_DIR"
}

download_new_version() {
    log_info "Downloading Funkwhale $FUNKWHALE_VERSION..."

    cd "$FUNKWHALE_DIR"

    log_info "Downloading API..."
    curl -L -o "api-$FUNKWHALE_VERSION.zip" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$FUNKWHALE_VERSION/download?job=build_api"

    log_info "Downloading Frontend..."
    curl -L -o "front-$FUNKWHALE_VERSION.zip" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$FUNKWHALE_VERSION/download?job=build_front"

    log_info "Downloads complete"
}

install_new_version() {
    log_info "Installing Funkwhale $FUNKWHALE_VERSION..."

    cd "$FUNKWHALE_DIR"

    log_info "Removing old API and frontend..."
    rm -rf api/* front/*

    log_info "Extracting API..."
    unzip -q "api-$FUNKWHALE_VERSION.zip" -d extracted
    mv extracted/api/* api/
    rm -rf extracted "api-$FUNKWHALE_VERSION.zip"

    log_info "Extracting frontend..."
    unzip -q "front-$FUNKWHALE_VERSION.zip" -d extracted
    rm -rf front/*
    mv extracted/front/* front/
    rm -rf extracted "front-$FUNKWHALE_VERSION.zip"

    # Funkwhale v2 uses venv instead of virtualenv
    log_info "Creating new Python virtual environment..."
    rm -rf venv
    python3 -m venv venv
    venv/bin/pip install --upgrade pip wheel

    log_info "Installing Funkwhale API package..."
    venv/bin/pip install --editable ./api

    chown -R funkwhale:funkwhale api front venv

    log_info "Installation complete"
}

update_systemd_units() {
    log_info "Updating systemd unit files..."

    local base_url="https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy"

    curl -L -o /etc/systemd/system/funkwhale.target "$base_url/funkwhale.target"
    curl -L -o /etc/systemd/system/funkwhale-server.service "$base_url/funkwhale-server.service"
    curl -L -o /etc/systemd/system/funkwhale-worker.service "$base_url/funkwhale-worker.service"
    curl -L -o /etc/systemd/system/funkwhale-beat.service "$base_url/funkwhale-beat.service"

    systemctl daemon-reload
    log_info "Systemd units updated"
}

update_nginx() {
    log_info "Updating nginx proxy configuration..."

    curl -L -o /etc/nginx/funkwhale_proxy.conf \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/funkwhale_proxy.conf"

    if nginx -t 2>&1; then
        log_info "Nginx configuration valid"
    else
        log_warn "Nginx configuration test had warnings (check output above)"
        log_warn "You may need to update your site config manually"
    fi
}

run_migrations() {
    log_info "Running database migrations..."

    cd "$FUNKWHALE_DIR"

    log_info "Collecting static files..."
    sudo -u funkwhale venv/bin/funkwhale-manage collectstatic --no-input

    log_info "Applying database migrations..."
    sudo -u funkwhale venv/bin/funkwhale-manage migrate

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

do_upgrade() {
    if [[ -z "$FUNKWHALE_VERSION" ]]; then
        log_error "Usage: $0 upgrade <version>"
        log_error "  e.g. $0 upgrade 2.0.0-rc15"
        exit 1
    fi

    log_info "Starting Funkwhale upgrade to $FUNKWHALE_VERSION"
    log_warn "Make sure you have a database backup before proceeding!"
    log_warn "  sudo -u postgres pg_dump funkwhale > backup.sql"

    check_root
    check_services_stopped
    detect_nginx_config

    backup_current
    download_new_version
    install_new_version
    update_systemd_units
    update_nginx
    run_migrations
    start_services

    log_info "=========================================="
    log_info "Upgrade complete!"
    log_info "Funkwhale $FUNKWHALE_VERSION is now running"
    log_info "=========================================="
    log_info "If something goes wrong, run: $0 rollback"
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

    log_info "Restoring systemd units..."
    cp "$BACKUP_DIR/systemd/"* /etc/systemd/system/
    systemctl daemon-reload

    if [[ -d "$BACKUP_DIR/nginx" ]]; then
        log_info "Restoring nginx config..."
        detect_nginx_config
        if [[ -n "$NGINX_SITE_CONFIG" ]]; then
            cp "$BACKUP_DIR/nginx/"*.conf "$(dirname "$NGINX_SITE_CONFIG")/" 2>/dev/null || true
        fi
        cp "$BACKUP_DIR/nginx/funkwhale_proxy.conf" /etc/nginx/ 2>/dev/null || true
    fi

    log_warn "NOTE: Database was NOT rolled back automatically."
    log_warn "To restore database, run:"
    log_warn "  sudo -u postgres psql funkwhale < your-backup.sql"

    systemctl start funkwhale.target
    systemctl reload nginx

    log_info "=========================================="
    log_info "Rollback complete!"
    log_info "=========================================="
}

show_status() {
    echo "Current Funkwhale installation:"
    echo "================================"

    if [[ -d "$FUNKWHALE_DIR/venv" ]]; then
        echo "Virtual env: venv (v2 style)"
        VERSION=$("$FUNKWHALE_DIR/venv/bin/pip" show funkwhale-api 2>/dev/null | grep Version | awk '{print $2}')
    elif [[ -d "$FUNKWHALE_DIR/virtualenv" ]]; then
        echo "Virtual env: virtualenv (v1 style)"
        VERSION=$("$FUNKWHALE_DIR/virtualenv/bin/pip" show funkwhale-api 2>/dev/null | grep Version | awk '{print $2}')
    fi

    echo "Installed version: ${VERSION:-unknown}"
    echo ""
    echo "Service status:"
    systemctl status funkwhale.target --no-pager 2>/dev/null || echo "  Not running"

    if [[ -f "$ROLLBACK_MARKER" ]]; then
        echo ""
        echo "Rollback available:"
        cat "$ROLLBACK_MARKER"
    fi
}

# Main
FUNKWHALE_VERSION="${2:-}"

case "${1:-}" in
    upgrade)
        do_upgrade
        ;;
    rollback)
        do_rollback
        ;;
    status)
        show_status
        ;;
    *)
        echo "Funkwhale v2 Upgrade Script"
        echo "==========================="
        echo ""
        echo "Usage: $0 <command> [version]"
        echo ""
        echo "Commands:"
        echo "  upgrade <version>  - Upgrade Funkwhale (e.g. $0 upgrade 2.0.0-rc15)"
        echo "  rollback           - Rollback to previous version"
        echo "  status             - Show current installation status"
        echo ""
        echo "Before upgrading:"
        echo "  1. Back up your database:  sudo -u postgres pg_dump funkwhale > backup.sql"
        echo "  2. Stop services:          systemctl stop funkwhale.target"
        echo ""
        ;;
esac
