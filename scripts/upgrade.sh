#!/bin/bash
#
# Funkwhale v2 Upgrade Script
# Upgrades between Funkwhale v2 releases with rollback capability.
#
# Usage:
#   ./upgrade.sh upgrade <version> [--with-db]   e.g. ./upgrade.sh upgrade 2.0.0-rc15
#   ./upgrade.sh rollback
#   ./upgrade.sh status
#
# Run from a checkout of this repo: systemd units and the nginx proxy config
# are installed from ../config.
#

set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

    if [[ -z "$FUNKWHALE_VERSION" ]]; then
        log_error "Usage: $0 upgrade <version> [--with-db]"
        log_error "  e.g. $0 upgrade 2.0.0-rc15"
        exit 1
    fi

    log_info "Starting Funkwhale upgrade to $FUNKWHALE_VERSION"
    if [[ "$with_db" != "true" ]]; then
        log_warn "No database backup will be taken. Pass --with-db, or make one yourself:"
        log_warn "  sudo -u postgres pg_dump -Fc $DB_NAME > $DB_NAME.dump"
    fi

    check_root
    check_services_stopped
    detect_nginx_config
    trap on_exit EXIT

    # Download and verify first: a failed download leaves the install untouched
    fetch_release "$FUNKWHALE_VERSION"
    backup_current "$with_db" "$FUNKWHALE_VERSION"
    install_release
    install_systemd_units
    install_proxy_conf
    run_migrations
    start_services
    record_installed_version "$FUNKWHALE_VERSION"

    log_info "=========================================="
    log_info "Upgrade complete!"
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
        echo "Funkwhale v2 Upgrade Script"
        echo "==========================="
        echo ""
        echo "Usage: $0 <command> [version] [--with-db]"
        echo ""
        echo "Commands:"
        echo "  upgrade <version>  - Upgrade Funkwhale (e.g. $0 upgrade 2.0.0-rc15)"
        echo "  rollback           - Rollback to previous version"
        echo "  status             - Show current installation status"
        echo ""
        echo "Options:"
        echo "  --with-db          - Also back up the PostgreSQL database (pg_dump -Fc)"
        echo ""
        echo "Before upgrading:"
        echo "  Stop services:  systemctl stop funkwhale.target"
        echo ""
        ;;
esac
