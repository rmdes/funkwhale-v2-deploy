#!/bin/bash
#
# Funkwhale v2 with Docker Compose: bootstrap and maintenance
#
# Usage:
#   ./funkwhale.sh init --domain music.example.com --email you@example.com [options]
#   ./funkwhale.sh upgrade [<version>]
#   ./funkwhale.sh rollback
#   ./funkwhale.sh backup
#   ./funkwhale.sh manage <funkwhale-manage arguments>
#
# Everything (config, data, backups) lives next to this script.
#

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"

DOCKERHUB_TAGS="${DOCKERHUB_TAGS:-https://hub.docker.com/v2/repositories/funkwhale/api/tags}"
FALLBACK_VERSION="2.0.11"
BACKUP_DIR="backups"
LAST_UPGRADE="$BACKUP_DIR/.last_upgrade"
BACKUP_FILE=""
CHANGES_STARTED=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

compose() { docker compose "$@"; }

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed. See https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log_error "The Docker Compose plugin is missing ('docker compose')."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        log_error "Cannot reach the Docker daemon. Run as root or as a user in the docker group."
        exit 1
    fi
}

require_init() {
    if [[ ! -f .env ]]; then
        log_error "No .env here. Run: $0 init --domain <domain> --email <email>"
        exit 1
    fi
}

random_hex() {
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

env_get() {
    sed -n "s/^$1=//p" .env | tail -n 1
}

env_set() {
    if grep -q "^$1=" .env; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        echo "$1=$2" >> .env
    fi
}

# Latest stable release, from the funkwhale/api image tags on Docker Hub
latest_version() {
    curl -fsS --max-time 30 "${DOCKERHUB_TAGS}?page_size=100&ordering=last_updated" 2>/dev/null |
        grep -oE '"name": *"[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
        sort -V | tail -n 1
}

# Funkwhale publishes -legacycpu images for amd64 CPUs without AVX2
needs_legacycpu() {
    [[ "$(uname -m)" == "x86_64" ]] && ! grep -qw avx2 /proc/cpuinfo 2>/dev/null
}

backup_database() {
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/funkwhale-$1-$(date +%Y%m%d_%H%M%S).dump"
    log_info "Backing up the database to $BACKUP_FILE..."
    compose up -d --wait postgres
    if ! compose exec -T postgres pg_dump -U funkwhale -Fc funkwhale > "$BACKUP_FILE" \
        || [[ ! -s "$BACKUP_FILE" ]]; then
        log_error "Database backup failed"
        rm -f "$BACKUP_FILE"
        exit 1
    fi
    log_info "Database backup: $(du -h "$BACKUP_FILE" | cut -f1)"
}

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 && "$CHANGES_STARTED" == "true" ]]; then
        log_error "Upgrade failed partway through. Go back to the previous version with:"
        log_error "  $0 rollback"
    fi
    return $rc
}

# ============== INIT ==============

do_init() {
    local domain="" email="" version="" tls=true http_bind="127.0.0.1:8080"
    local legacy=auto admin_user="" project=funkwhale

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift ;;
            --email) email="$2"; shift ;;
            --version) version="$2"; shift ;;
            --no-tls) tls=false ;;
            --http-bind) http_bind="$2"; shift ;;
            --legacycpu) legacy=true ;;
            --no-legacycpu) legacy=false ;;
            --admin-user) admin_user="$2"; shift ;;
            --project) project="$2"; shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done

    if [[ -f .env ]]; then
        log_error "Already initialized (.env exists). Use '$0 upgrade', or remove .env and data/ to start over."
        exit 1
    fi
    if [[ -z "$domain" ]]; then
        log_error "Usage: $0 init --domain <domain> --email <email> [options]"
        exit 1
    fi
    if [[ "$tls" == "true" && -z "$email" ]]; then
        log_error "--email is required for the Let's Encrypt certificate (or pass --no-tls)"
        exit 1
    fi

    # Default admin username: the email's local part ("admin" and similar are reserved by Funkwhale)
    if [[ -z "$admin_user" ]]; then
        admin_user=$(echo "${email%%@*}" | tr -cd 'A-Za-z0-9_')
        admin_user="${admin_user:-fwadmin}"
    fi

    check_docker

    if [[ -z "$version" ]]; then
        log_info "Looking up the latest Funkwhale release..."
        version=$(latest_version || true)
        if [[ -z "$version" ]]; then
            version="$FALLBACK_VERSION"
            log_warn "Could not reach Docker Hub; using $version"
        fi
    fi
    if [[ "$legacy" == "auto" ]] && needs_legacycpu; then
        log_info "This CPU has no AVX2 support; using the -legacycpu images"
        legacy=true
    fi
    if [[ "$legacy" == "true" && "$version" != *-legacycpu ]]; then
        version="$version-legacycpu"
    fi

    local workers
    workers=$(nproc 2>/dev/null || echo 2)
    (( workers > 4 )) && workers=4

    local db_password
    db_password=$(random_hex 24)

    log_info "Writing .env for $domain (Funkwhale $version)..."
    (
        umask 077
        cat > .env <<EOF
# Generated by funkwhale.sh init on $(date). Keep this file secret.
COMPOSE_PROJECT_NAME=$project
COMPOSE_PROFILES=$([[ "$tls" == "true" ]] && echo caddy)
FUNKWHALE_VERSION=$version

FUNKWHALE_HOSTNAME=$domain
FUNKWHALE_PROTOCOL=https
LETSENCRYPT_EMAIL=$email
# Where the front container listens on this host (for your own reverse proxy)
FUNKWHALE_HTTP_BIND=$http_bind
# Host ports for Caddy
CADDY_HTTP_PORT=${CADDY_HTTP_PORT:-80}
CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT:-443}

DJANGO_SECRET_KEY=$(random_hex 32)
POSTGRES_PASSWORD=$db_password
DATABASE_URL=postgresql://funkwhale:$db_password@postgres:5432/funkwhale
CACHE_URL=redis://redis:6379/0

FUNKWHALE_API_HOST=api
FUNKWHALE_API_PORT=5000
FUNKWHALE_WEB_WORKERS=$workers
CELERYD_CONCURRENCY=0
REVERSE_PROXY_TYPE=nginx
NGINX_MAX_BODY_SIZE=2000M

MEDIA_ROOT=/srv/funkwhale/data/media
STATIC_ROOT=/srv/funkwhale/data/static
MUSIC_DIRECTORY_PATH=/music
EOF
        # On a non-standard HTTPS port, browsers send it in the Origin header, and Django
        # rejects logins (CSRF) unless that origin is trusted. Trusted origins come from the
        # allowed hosts.
        if [[ "$tls" == "true" && "${CADDY_HTTPS_PORT:-443}" != "443" ]]; then
            echo "DJANGO_ALLOWED_HOSTS=$domain:$CADDY_HTTPS_PORT" >> .env
        fi
    )

    mkdir -p data/media data/music data/static data/postgres data/redis data/caddy "$BACKUP_DIR"

    log_info "Pulling images..."
    compose pull --quiet

    log_info "Starting the database..."
    compose up -d --wait postgres redis

    log_info "Running database migrations..."
    compose run --rm api funkwhale-manage migrate

    log_info "Collecting static files..."
    compose run --rm api funkwhale-manage collectstatic --no-input

    # Funkwhale refuses Django's createsuperuser and asks for its own command.
    # A failure here (e.g. a reserved username) shouldn't abort a half-done init.
    log_info "Creating the admin account $admin_user..."
    local admin_password admin_created=true
    admin_password=$(random_hex 12)
    if ! compose run --rm api funkwhale-manage fw users create --superuser \
        --username "$admin_user" --email "${email:-$admin_user@$domain}" --password "$admin_password"; then
        admin_created=false
        log_warn "Could not create the admin account (see above). Create it with:"
        log_warn "  $0 manage fw users create --superuser --username <name> --email <email> --password <password>"
    fi

    log_info "Starting Funkwhale..."
    compose up -d

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Funkwhale $version is running${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    if [[ "$tls" == "true" ]]; then
        echo -e "  URL:    ${CYAN}https://$domain${NC}"
        echo "          (DNS for $domain must point here, with ports 80 and 443 open;"
        echo "           the certificate is fetched on first start)"
    else
        echo -e "  App:    ${CYAN}http://$http_bind${NC}  (put your HTTPS reverse proxy in front, see README)"
    fi
    if [[ "$admin_created" == "true" ]]; then
        echo -e "  Admin:  ${CYAN}$admin_user${NC} / ${CYAN}$admin_password${NC}"
        echo "          Shown only once: log in and change it."
    fi
    echo "  Data:   $(pwd)/data"
    echo ""
}

# ============== UPGRADE ==============

do_upgrade() {
    require_init
    check_docker

    local current target
    current=$(env_get FUNKWHALE_VERSION)
    target="${1:-}"

    if [[ -z "$target" ]]; then
        target=$(latest_version || true)
        if [[ -z "$target" ]]; then
            log_error "Could not look up the latest release on Docker Hub. Pass a version: $0 upgrade <version>"
            exit 1
        fi
    fi
    # Stay on the -legacycpu images if that's what this instance uses
    if [[ "$current" == *-legacycpu && "$target" != *-legacycpu ]]; then
        target="$target-legacycpu"
    fi

    if [[ "$target" == "$current" ]]; then
        log_info "Already running $current"
        return 0
    fi

    log_info "Upgrading Funkwhale $current → $target"

    # Pull first: an unknown version fails here, before anything changes
    log_info "Pulling $target images..."
    if ! FUNKWHALE_VERSION="$target" compose pull --quiet api front; then
        log_error "Could not pull Funkwhale $target. Nothing was changed."
        exit 1
    fi

    trap on_exit EXIT
    backup_database "$current"
    printf '%s\n%s\n' "$current" "$BACKUP_FILE" > "$LAST_UPGRADE"

    CHANGES_STARTED=true
    compose stop api celeryworker celerybeat front
    env_set FUNKWHALE_VERSION "$target"

    log_info "Running database migrations..."
    compose run --rm api funkwhale-manage migrate
    log_info "Collecting static files..."
    compose run --rm api funkwhale-manage collectstatic --no-input

    compose up -d
    log_info "Funkwhale $target is running. If something is wrong: $0 rollback"
}

# ============== ROLLBACK ==============

do_rollback() {
    require_init
    check_docker

    if [[ ! -f "$LAST_UPGRADE" ]]; then
        log_error "No upgrade to roll back"
        exit 1
    fi

    local old_version dump
    old_version=$(sed -n 1p "$LAST_UPGRADE")
    dump=$(sed -n 2p "$LAST_UPGRADE")

    echo -e "  Back to version:  ${YELLOW}$old_version${NC}"
    echo -e "  Restore database: ${YELLOW}$dump${NC} (changes since the upgrade are lost)"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Rollback cancelled"
        exit 1
    fi

    compose stop api celeryworker celerybeat front
    env_set FUNKWHALE_VERSION "$old_version"

    # Recreate the database rather than pg_restore --clean: objects added by the
    # newer migrations aren't in the dump and would block dropping the old ones
    log_info "Restoring the database..."
    compose up -d --wait postgres
    compose exec -T postgres dropdb -U funkwhale --force funkwhale
    compose exec -T postgres createdb -U funkwhale -O funkwhale funkwhale
    compose exec -T postgres pg_restore -U funkwhale -d funkwhale < "$dump"

    compose up -d
    rm -f "$LAST_UPGRADE"
    log_info "Rolled back to Funkwhale $old_version"
}

# ============== MAIN ==============

case "${1:-}" in
    init)
        shift
        do_init "$@"
        ;;
    upgrade)
        do_upgrade "${2:-}"
        ;;
    rollback)
        do_rollback
        ;;
    backup)
        require_init
        check_docker
        backup_database "$(env_get FUNKWHALE_VERSION)"
        log_info "Media and music files are in $(pwd)/data; back that up too."
        ;;
    manage)
        require_init
        shift
        compose run --rm api funkwhale-manage "$@"
        ;;
    *)
        echo "Funkwhale v2 with Docker Compose"
        echo "================================"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  init                Set up a new instance and start it"
        echo "  upgrade [version]   Upgrade (default: latest release), backing up the database first"
        echo "  rollback            Undo the last upgrade (version and database)"
        echo "  backup              Dump the database to $BACKUP_DIR/"
        echo "  manage <args>       Run funkwhale-manage, e.g. '$0 manage changepassword admin'"
        echo ""
        echo "init options:"
        echo "  --domain <domain>   Public hostname (required)"
        echo "  --email <email>     Let's Encrypt and admin email (required unless --no-tls)"
        echo "  --version <x.y.z>   Funkwhale version (default: latest release)"
        echo "  --no-tls            Skip the bundled Caddy; use your own HTTPS reverse proxy"
        echo "  --http-bind <addr>  Where the app listens for that proxy (default: 127.0.0.1:8080)"
        echo "  --legacycpu         Force the -legacycpu images (auto-detected on CPUs without AVX2)"
        echo "  --admin-user <name> Admin account name (default: the part of --email before @)"
        echo ""
        echo "Use 'docker compose ps' / 'docker compose logs -f' here for status and logs."
        echo ""
        ;;
esac
