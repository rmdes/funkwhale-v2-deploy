# funkwhale-v2-deploy

Bare-metal deployment toolkit and Ansible role for [Funkwhale](https://funkwhale.audio/) v2.

Funkwhale is a self-hosted, federated music streaming platform. This repo provides everything needed to deploy and upgrade a Funkwhale v2 instance on a Debian/Ubuntu server without Docker.

## Two deployment paths

### 1. Manual deployment (scripts + config templates)

For those who prefer to set things up by hand or already have a running instance.

**What's included:**

- `config/.env.example` - Funkwhale environment configuration template
- `config/nginx/` - nginx site and proxy configuration
- `config/systemd/` - systemd service units (server, worker, beat, target)
- `config/logrotate/` - log rotation config
- `scripts/upgrade.sh` - upgrade script with rollback support

**Quick start:**

```bash
# 1. Create system user
sudo useradd -r -s /bin/bash -m -d /srv/funkwhale funkwhale

# 2. Set up PostgreSQL
sudo -u postgres createuser funkwhale
sudo -u postgres createdb -O funkwhale funkwhale

# 3. Copy and edit configuration
sudo mkdir -p /srv/funkwhale/config
sudo cp config/.env.example /srv/funkwhale/config/.env
sudo nano /srv/funkwhale/config/.env   # Set your domain + generate secret key

# 4. Download and install Funkwhale (replace version as needed)
VERSION="2.0.0-rc15"
cd /srv/funkwhale
sudo -u funkwhale curl -L -o api.zip \
  "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$VERSION/download?job=build_api"
sudo -u funkwhale curl -L -o front.zip \
  "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$VERSION/download?job=build_front"
sudo -u funkwhale unzip api.zip && sudo -u funkwhale unzip front.zip
rm api.zip front.zip

# 5. Set up Python venv and install
sudo -u funkwhale python3 -m venv /srv/funkwhale/venv
sudo -u funkwhale /srv/funkwhale/venv/bin/pip install --upgrade pip wheel
sudo -u funkwhale /srv/funkwhale/venv/bin/pip install --editable ./api

# 6. Run initial setup
sudo -u funkwhale /srv/funkwhale/venv/bin/funkwhale-manage collectstatic --no-input
sudo -u funkwhale /srv/funkwhale/venv/bin/funkwhale-manage migrate
sudo -u funkwhale /srv/funkwhale/venv/bin/funkwhale-manage createsuperuser

# 7. Deploy service configs
sudo cp config/systemd/* /etc/systemd/system/
sudo cp config/nginx/funkwhale_proxy.conf /etc/nginx/
# Edit config/nginx/funkwhale.conf - replace YOUR_DOMAIN with your domain
sudo cp config/nginx/funkwhale.conf /etc/nginx/sites-available/your-domain.conf
sudo ln -s /etc/nginx/sites-available/your-domain.conf /etc/nginx/sites-enabled/
sudo cp config/logrotate/funkwhale /etc/logrotate.d/

# 8. Get SSL certificate and start
sudo certbot --nginx -d your-domain.example.com
sudo systemctl daemon-reload
sudo systemctl enable --now funkwhale.target
sudo systemctl reload nginx
```

### 2. Ansible deployment (automated)

For automated, repeatable deployments.

**Requirements:**

- Ansible 2.12+ on your control machine
- `community.postgresql` collection: `ansible-galaxy collection install community.postgresql`
- A Debian 12+ or Ubuntu 22.04+ target server with SSH root access

**Quick start:**

```bash
cd ansible/

# 1. Set up inventory
cp inventory.example inventory
nano inventory   # Set your server address

# 2. Configure variables
cp group_vars/all.yml.example group_vars/all.yml
nano group_vars/all.yml   # Set domain, email, version

# 3. Deploy
ansible-playbook -i inventory playbook.yml
```

**Variables reference:**

| Variable | Default | Description |
|----------|---------|-------------|
| `funkwhale_hostname` | (required) | Your domain name |
| `certbot_email` | (required) | Email for Let's Encrypt |
| `funkwhale_version` | `2.0.0-rc15` | Funkwhale version to deploy |
| `funkwhale_web_workers` | `4` | Gunicorn worker count |
| `funkwhale_api_port` | `5000` | API listening port |
| `funkwhale_fresh_install` | `true` | Set to `false` for upgrades |

## Migrating from Funkwhale 1.x

If you're upgrading from Funkwhale 1.4.x to v2, use the migration script:

```bash
# Check current installation
sudo bash scripts/migrate-v1-to-v2.sh status

# Stop services first
sudo systemctl stop funkwhale.target

# Run the migration (backs up everything, then upgrades)
sudo bash scripts/migrate-v1-to-v2.sh upgrade

# If something goes wrong
sudo bash scripts/migrate-v1-to-v2.sh rollback
```

This handles the full v1→v2 transition: backing up the old `virtualenv`, creating a new `venv`, downloading v2 artifacts, updating systemd units and nginx config, and running database migrations.

## Upgrading between v2 releases

For ongoing upgrades (e.g., between release candidates), use the updater:

```bash
# Check for available updates
./scripts/funkwhale-updater.sh check

# Upgrade to latest version
./scripts/funkwhale-updater.sh upgrade

# Upgrade to a specific version (with database backup)
./scripts/funkwhale-updater.sh upgrade 2.0.0-rc15 --with-db

# If something goes wrong
./scripts/funkwhale-updater.sh rollback
```

The updater queries the Funkwhale GitLab API for available versions and handles the full lifecycle: stop → backup → download → install → migrate → start → verify.

You can also use the simpler upgrade script:

```bash
sudo bash scripts/upgrade.sh status
sudo systemctl stop funkwhale.target
sudo bash scripts/upgrade.sh upgrade 2.0.0-rc15
sudo bash scripts/upgrade.sh rollback  # if needed
```

## Architecture

```
/srv/funkwhale/
├── api/          # Django REST API (Python)
├── front/        # Vue.js frontend (static files)
├── venv/         # Python virtual environment
├── config/
│   └── .env      # Environment configuration
├── data/
│   ├── media/    # User uploads
│   ├── music/    # Music library
│   └── static/   # Django static files
└── backups/      # Upgrade backups
```

**Services:**
- `funkwhale-server` - Gunicorn/Uvicorn ASGI server
- `funkwhale-worker` - Celery async task worker
- `funkwhale-beat` - Celery periodic task scheduler
- `funkwhale.target` - systemd target grouping all services

## Notes

- This is tested against Funkwhale v2 (currently in release candidate stage). v2 is a significant rewrite from v1 and is not yet stable.
- The nginx config uses TLS 1.3 only (Mozilla modern profile). Adjust if you need to support older clients.
- The `CELERYD_CONCURRENCY=0` setting means Celery auto-detects the number of worker processes based on CPU cores.

## License

MIT
