#!/bin/bash
#
# Funkwhale Upgrade Script: 1.4.0 -> 2.0.0-rc5
# With rollback capability
#
# Usage: ./upgrade-funkwhale-2.0.sh [upgrade|rollback|status]
#

set -e

# Configuration
FUNKWHALE_VERSION="2.0.0-rc5"
FUNKWHALE_DIR="/srv/funkwhale"
BACKUP_DIR="/srv/funkwhale/backups/upgrade-$(date +%Y%m%d_%H%M%S)"
ROLLBACK_MARKER="/srv/funkwhale/backups/.rollback_info"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
        log_error "Funkwhale services are still running. Stop them first with: systemctl stop funkwhale.target"
        exit 1
    fi
}

backup_current() {
    log_info "Creating backup in $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"

    # Backup current installation
    log_info "Backing up API..."
    cp -a "$FUNKWHALE_DIR/api" "$BACKUP_DIR/api"

    log_info "Backing up frontend..."
    cp -a "$FUNKWHALE_DIR/front" "$BACKUP_DIR/front"

    log_info "Backing up virtualenv..."
    cp -a "$FUNKWHALE_DIR/virtualenv" "$BACKUP_DIR/virtualenv"

    log_info "Backing up config..."
    cp -a "$FUNKWHALE_DIR/config" "$BACKUP_DIR/config"

    log_info "Backing up systemd units..."
    mkdir -p "$BACKUP_DIR/systemd"
    cp /etc/systemd/system/funkwhale*.service "$BACKUP_DIR/systemd/" 2>/dev/null || true
    cp /etc/systemd/system/funkwhale.target "$BACKUP_DIR/systemd/" 2>/dev/null || true

    log_info "Backing up nginx config..."
    mkdir -p "$BACKUP_DIR/nginx"
    cp /etc/nginx/sites-enabled/*.conf "$BACKUP_DIR/nginx/" 2>/dev/null || true
    cp /etc/nginx/funkwhale_proxy.conf "$BACKUP_DIR/nginx/" 2>/dev/null || true

    # Save rollback info
    echo "$BACKUP_DIR" > "$ROLLBACK_MARKER"
    echo "BACKUP_DATE=$(date)" >> "$ROLLBACK_MARKER"
    echo "OLD_VERSION=1.4.0" >> "$ROLLBACK_MARKER"
    echo "NEW_VERSION=$FUNKWHALE_VERSION" >> "$ROLLBACK_MARKER"

    log_info "Backup complete: $BACKUP_DIR"
}

download_new_version() {
    log_info "Downloading Funkwhale $FUNKWHALE_VERSION..."

    cd "$FUNKWHALE_DIR"

    # Download API
    log_info "Downloading API..."
    curl -L -o "api-$FUNKWHALE_VERSION.zip" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$FUNKWHALE_VERSION/download?job=build_api"

    # Download Frontend
    log_info "Downloading Frontend..."
    curl -L -o "front-$FUNKWHALE_VERSION.zip" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$FUNKWHALE_VERSION/download?job=build_front"

    log_info "Downloads complete"
}

install_new_version() {
    log_info "Installing Funkwhale $FUNKWHALE_VERSION..."

    cd "$FUNKWHALE_DIR"

    # Remove old files (keep data!)
    log_info "Removing old API and frontend..."
    rm -rf api/* front/*

    # Extract new API
    log_info "Extracting API..."
    unzip -q "api-$FUNKWHALE_VERSION.zip" -d extracted
    mv extracted/api/* api/
    rm -rf extracted "api-$FUNKWHALE_VERSION.zip"

    # Extract new frontend
    log_info "Extracting frontend..."
    unzip -q "front-$FUNKWHALE_VERSION.zip" -d extracted
    rm -rf front/*
    mv extracted/front/* front/
    rm -rf extracted "front-$FUNKWHALE_VERSION.zip"

    # Create new venv (2.0 uses venv instead of virtualenv)
    log_info "Creating new Python virtual environment..."
    rm -rf venv
    python3 -m venv venv
    venv/bin/pip install --upgrade pip wheel

    # Install API package
    log_info "Installing Funkwhale API package..."
    venv/bin/pip install --editable ./api

    # Set permissions
    chown -R funkwhale:funkwhale api front venv

    log_info "Installation complete"
}

update_systemd_units() {
    log_info "Updating systemd unit files..."

    # Download new unit files
    curl -L -o "/etc/systemd/system/funkwhale.target" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/funkwhale.target"
    curl -L -o "/etc/systemd/system/funkwhale-server.service" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/funkwhale-server.service"
    curl -L -o "/etc/systemd/system/funkwhale-worker.service" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/funkwhale-worker.service"
    curl -L -o "/etc/systemd/system/funkwhale-beat.service" \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/funkwhale-beat.service"

    systemctl daemon-reload
    log_info "Systemd units updated"
}

update_nginx() {
    log_info "Updating nginx configuration..."

    # Download new nginx template
    curl -L -o /etc/nginx/funkwhale_proxy.conf \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/funkwhale_proxy.conf"
    curl -L -o /etc/nginx/sites-available/funkwhale.template \
        "https://dev.funkwhale.audio/funkwhale/funkwhale/raw/$FUNKWHALE_VERSION/deploy/nginx.template"

    # Generate config from template
    set -a && source /srv/funkwhale/config/.env && set +a
    envsubst "$(env | awk -F = '{printf " $%s", $1}')" \
        < /etc/nginx/sites-available/funkwhale.template \
        > /etc/nginx/sites-available/funkwhale.conf

    # Test nginx config
    if nginx -t; then
        log_info "Nginx configuration valid"
    else
        log_error "Nginx configuration invalid!"
        exit 1
    fi
}

run_migrations() {
    log_info "Running database migrations..."

    cd "$FUNKWHALE_DIR"

    # Collect static files
    log_info "Collecting static files..."
    sudo -u funkwhale venv/bin/funkwhale-manage collectstatic --no-input

    # Run migrations
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
        log_error "Services failed to start. Check logs with: journalctl -u funkwhale-server.service"
        exit 1
    fi
}

do_upgrade() {
    log_info "Starting Funkwhale upgrade to $FUNKWHALE_VERSION"
    log_warn "Make sure you have a database backup before proceeding!"

    check_root
    check_services_stopped

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

    # Restore files
    log_info "Restoring API..."
    rm -rf "$FUNKWHALE_DIR/api"
    cp -a "$BACKUP_DIR/api" "$FUNKWHALE_DIR/api"

    log_info "Restoring frontend..."
    rm -rf "$FUNKWHALE_DIR/front"
    cp -a "$BACKUP_DIR/front" "$FUNKWHALE_DIR/front"

    log_info "Restoring virtualenv..."
    rm -rf "$FUNKWHALE_DIR/venv" "$FUNKWHALE_DIR/virtualenv"
    cp -a "$BACKUP_DIR/virtualenv" "$FUNKWHALE_DIR/virtualenv"

    log_info "Restoring systemd units..."
    cp "$BACKUP_DIR/systemd/"* /etc/systemd/system/
    systemctl daemon-reload

    log_info "Restoring nginx config..."
    cp "$BACKUP_DIR/nginx/"* /etc/nginx/sites-enabled/ 2>/dev/null || true
    cp "$BACKUP_DIR/nginx/funkwhale_proxy.conf" /etc/nginx/ 2>/dev/null || true

    # Restore database from backup
    log_warn "NOTE: Database was NOT rolled back automatically."
    log_warn "To restore database, run:"
    log_warn "  sudo -u postgres psql < /srv/funkwhale/backups/dump_*.sql"

    # Start services
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
        echo "Virtual env: venv (2.0 style)"
        VERSION=$("$FUNKWHALE_DIR/venv/bin/pip" show funkwhale-api 2>/dev/null | grep Version | awk '{print $2}')
    elif [[ -d "$FUNKWHALE_DIR/virtualenv" ]]; then
        echo "Virtual env: virtualenv (1.x style)"
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
        echo "Funkwhale Upgrade Script"
        echo "========================"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  upgrade   - Upgrade Funkwhale to $FUNKWHALE_VERSION"
        echo "  rollback  - Rollback to previous version"
        echo "  status    - Show current installation status"
        echo ""
        echo "Before upgrading:"
        echo "  1. Ensure database is backed up"
        echo "  2. Ensure media files are backed up"
        echo "  3. Stop services: systemctl stop funkwhale.target"
        echo ""
        ;;
esac
