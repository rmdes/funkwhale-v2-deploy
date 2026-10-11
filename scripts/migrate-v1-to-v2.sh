#!/bin/bash
#
# Funkwhale Migration Script: 1.4.x -> 2.0.0
# With rollback capability
#
# Usage: ./migrate-v1-to-v2.sh [upgrade [version] [--with-db]|rollback|status]
#
# Defaults to 2.0.0-rc5, the release this migration was tested with. Afterwards,
# move to newer v2 releases with upgrade.sh or funkwhale-updater.sh.
#
# Run from a checkout of this repo: systemd units and nginx configs are
# installed from ../config.
#

set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEFAULT_VERSION="2.0.0-rc5"

# Generate the v2 nginx site config from config/nginx/funkwhale.conf.
# Overwrites the site config currently in use, or creates <hostname>.conf.
write_site_config() {
    local hostname api_ip api_port target
    hostname=$(env_value FUNKWHALE_HOSTNAME)
    api_ip=$(env_value FUNKWHALE_API_IP)
    api_port=$(env_value FUNKWHALE_API_PORT)

    if [[ -z "$hostname" ]]; then
        log_error "FUNKWHALE_HOSTNAME is not set in $FUNKWHALE_DIR/config/.env"
        exit 1
    fi

    target="${NGINX_SITE_CONFIG:-$NGINX_DIR/sites-available/$hostname.conf}"
    log_info "Writing nginx site config to $target..."
    sed -e "s/YOUR_DOMAIN/$hostname/g" \
        -e "s/127\.0\.0\.1:5000/${api_ip:-127.0.0.1}:${api_port:-5000}/g" \
        -e "s#/srv/funkwhale#$FUNKWHALE_DIR#g" \
        "$REPO_DIR/config/nginx/funkwhale.conf" > "$target"

    if [[ -z "$NGINX_SITE_CONFIG" ]]; then
        ln -sf "$target" "$NGINX_DIR/sites-enabled/$hostname.conf"
    fi

    if nginx -t; then
        log_info "Nginx configuration valid"
    else
        log_error "Nginx configuration invalid! (see output above)"
        exit 1
    fi
}

do_upgrade() {
    local with_db="false"
    FUNKWHALE_VERSION=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-db) with_db="true" ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) FUNKWHALE_VERSION="$1" ;;
        esac
        shift
    done
    FUNKWHALE_VERSION="${FUNKWHALE_VERSION:-$DEFAULT_VERSION}"

    log_info "Starting Funkwhale migration to $FUNKWHALE_VERSION"
    if [[ "$with_db" != "true" ]]; then
        log_warn "No database backup will be taken. Pass --with-db, or make one yourself:"
        log_warn "  sudo -u postgres pg_dump -Fc $DB_NAME > $DB_NAME.dump"
    fi

    check_root
    check_services_stopped

    if [[ ! -d "$FUNKWHALE_DIR/virtualenv" ]]; then
        log_error "No v1 virtualenv found in $FUNKWHALE_DIR. For v2 -> v2 upgrades use upgrade.sh."
        exit 1
    fi

    detect_nginx_config
    trap on_exit EXIT

    # Download and verify first: a failed download leaves the install untouched
    fetch_release "$FUNKWHALE_VERSION"
    backup_current "$with_db" "$FUNKWHALE_VERSION"
    install_release
    install_systemd_units
    install_proxy_conf
    write_site_config
    run_migrations
    start_services
    record_installed_version "$FUNKWHALE_VERSION"

    log_info "=========================================="
    log_info "Migration complete!"
    log_info "Funkwhale $FUNKWHALE_VERSION is now running"
    log_info "=========================================="
    log_info "If something goes wrong, run: $0 rollback"
}

# Main
case "${1:-}" in
    upgrade)
        shift
        do_upgrade "$@"
        ;;
    rollback)
        do_rollback
        ;;
    status)
        show_status
        ;;
    *)
        echo "Funkwhale v1 -> v2 Migration Script"
        echo "==================================="
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  upgrade [version]  - Migrate Funkwhale 1.x to v2 (default: $DEFAULT_VERSION)"
        echo "  rollback           - Rollback to previous version"
        echo "  status             - Show current installation status"
        echo ""
        echo "Options:"
        echo "  --with-db          - Also back up the PostgreSQL database (pg_dump -Fc)"
        echo ""
        echo "Before upgrading:"
        echo "  1. Ensure media files are backed up"
        echo "  2. Stop services: systemctl stop funkwhale.target"
        echo ""
        ;;
esac
