# funkwhale-v2-deploy

Bare-metal deployment toolkit and Ansible role for [Funkwhale](https://funkwhale.audio/) v2.

Funkwhale is a self-hosted, federated music streaming platform. This repo provides everything needed to deploy and upgrade a Funkwhale v2 instance on a Debian/Ubuntu server without Docker.

## Two deployment paths

### 1. Manual deployment (scripts + config templates)

For those who prefer to set things up by hand or already have a running instance.

**What's included:**

- `config/.env.example` - Funkwhale environment configuration template
- `config/nginx/` - nginx site and proxy configuration, plus an HTTP-only site used to get the first certificate
- `config/systemd/` - systemd service units (server, worker, beat, target)
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
sudo -u funkwhale curl -fL -o api.zip \
  "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$VERSION/download?job=build_api"
sudo -u funkwhale curl -fL -o front.zip \
  "https://dev.funkwhale.audio/funkwhale/funkwhale/-/jobs/artifacts/$VERSION/download?job=build_front"
sudo -u funkwhale unzip api.zip && sudo -u funkwhale unzip front.zip
sudo rm api.zip front.zip
sudo -u funkwhale mkdir -p data/media data/music data/static

# 5. Set up Python venv and install
sudo -u funkwhale python3 -m venv /srv/funkwhale/venv
sudo -u funkwhale /srv/funkwhale/venv/bin/pip install --upgrade pip wheel
sudo -u funkwhale /srv/funkwhale/venv/bin/pip install --editable ./api

# 6. Run initial setup (from api/, the services' working directory)
cd /srv/funkwhale/api
sudo -u funkwhale /srv/funkwhale/venv/bin/funkwhale-manage collectstatic --no-input
sudo -u funkwhale /srv/funkwhale/venv/bin/funkwhale-manage migrate
sudo -u funkwhale /srv/funkwhale/venv/bin/funkwhale-manage createsuperuser
cd -   # back to this repo

# 7. Deploy service configs
sudo cp config/systemd/* /etc/systemd/system/
sudo cp config/nginx/funkwhale_proxy.conf /etc/nginx/

# 8. Get the TLS certificate. The full site config needs the certificate to exist,
#    so start with an HTTP-only site for the challenge.
DOMAIN="your-domain.example.com"
sed "s/YOUR_DOMAIN/$DOMAIN/g" config/nginx/funkwhale_bootstrap.conf \
  | sudo tee /etc/nginx/sites-available/$DOMAIN.conf >/dev/null
sudo ln -s /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
sudo systemctl reload nginx
sudo certbot certonly --nginx -d $DOMAIN
# Reload nginx after each automatic renewal (certbot.timer handles renewals)
printf '#!/bin/sh\nsystemctl reload nginx\n' \
  | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# 9. Install the full site config and start
sed "s/YOUR_DOMAIN/$DOMAIN/g" config/nginx/funkwhale.conf \
  | sudo tee /etc/nginx/sites-available/$DOMAIN.conf >/dev/null
sudo nginx -t
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

The playbook is safe to re-run: the Django secret key is read back from the existing `.env` and only generated on first deploy. On first deploy it serves an HTTP-only site to obtain the certificate, then installs the full config. Renewals are handled by `certbot.timer`, with a deploy hook that reloads nginx.

**Variables reference** (defaults live in `roles/funkwhale/defaults/main.yml`):

| Variable | Default | Description |
|----------|---------|-------------|
| `funkwhale_hostname` | (required) | Your domain name |
| `certbot_email` | (required) | Email for Let's Encrypt |
| `funkwhale_version` | `2.0.0-rc15` | Funkwhale version to deploy |
| `funkwhale_web_workers` | `4` | Gunicorn worker count |
| `funkwhale_api_ip` | `127.0.0.1` | API listening address |
| `funkwhale_api_port` | `5000` | API listening port |
| `funkwhale_dir` | `/srv/funkwhale` | Install directory |
| `funkwhale_data_dir` | `{{ funkwhale_dir }}/data` | Media, music and static files |
| `nginx_max_body_size` | `2000M` | Upload size limit |
| `funkwhale_fresh_install` | `true` | Create the admin account (harmless if it already exists) |
| `funkwhale_admin_username` | `admin` | Admin account name |
| `funkwhale_admin_email` | `{{ certbot_email }}` | Admin account email |
| `funkwhale_admin_password` | `""` | Admin password; if empty, set it later with `funkwhale-manage changepassword` |

## Migrating from Funkwhale 1.x

If you're upgrading from Funkwhale 1.4.x to v2, use the migration script:

```bash
# Check current installation
sudo bash scripts/migrate-v1-to-v2.sh status

# Stop services first
sudo systemctl stop funkwhale.target

# Run the migration (backs up everything, then upgrades)
sudo bash scripts/migrate-v1-to-v2.sh upgrade --with-db

# If something goes wrong
sudo bash scripts/migrate-v1-to-v2.sh rollback
```

This handles the full v1→v2 transition: backing up the old `virtualenv`, creating a new `venv`, downloading v2 artifacts, installing the systemd units and nginx config from this repo, and running database migrations. It writes the v2 nginx site over the site config currently in use (or creates `<hostname>.conf`).

It migrates to `2.0.0-rc5`, the release it was tested with. Pass another version to override (`upgrade 2.0.0-rc15`), or migrate to rc5 and then use the updater below.

## Upgrading between v2 releases

For ongoing upgrades (e.g., between release candidates), use the updater. It runs on the server with sudo, or from another machine over SSH:

```bash
# Check for available updates
./scripts/funkwhale-updater.sh check

# Upgrade to latest version
./scripts/funkwhale-updater.sh upgrade

# Upgrade to a specific version (with database backup)
./scripts/funkwhale-updater.sh upgrade 2.0.0-rc15 --with-db

# If something goes wrong
./scripts/funkwhale-updater.sh rollback

# Run any of these against a remote server
SSH_HOST=my-server ./scripts/funkwhale-updater.sh check
```

The updater queries the Funkwhale GitLab API for available versions and handles the full lifecycle: download and verify → stop → backup → install → migrate → start → verify. The new release is downloaded and checked while the old version is still running, so a failed download changes nothing. If the backup fails, services are restarted and nothing is changed.

You can also use the simpler upgrade script, which also reinstalls the systemd units and nginx proxy config from this repo (run it from a checkout of the repo):

```bash
sudo bash scripts/upgrade.sh status
sudo systemctl stop funkwhale.target
sudo bash scripts/upgrade.sh upgrade 2.0.0-rc15 --with-db
sudo bash scripts/upgrade.sh rollback  # if needed
```

**Backups and rollback:** each upgrade stores a backup in `/srv/funkwhale/backups/upgrade-<date>/` (code, venv, config, systemd units, nginx files and, with `--with-db`, a `pg_dump -Fc` database dump). Only the newest 3 are kept; set `KEEP_BACKUPS` to change that. Rollback restores all of it and offers to restore the database with `pg_restore --clean`. All three scripts share the same rollback record, so any of them can roll back an upgrade made by another.

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
