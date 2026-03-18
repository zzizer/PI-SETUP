#!/bin/bash

set -euo pipefail

# ══════════════════════════════════════════════════════════════════
#  BAIFAM Device Setup Script
#  Usage: sudo bash setup.sh [device-name]
#  Example: sudo bash setup.sh server
# ══════════════════════════════════════════════════════════════════

# ─── Resolve real user (works whether called with sudo or not) ────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ─── Configuration ────────────────────────────────────────────────
DEVICE_NAME="${1:-server}"
APP_PARENT="/opt/app"
APP_DIR="$APP_PARENT/PROJECT-BAIFAM"
REPOSITORY_URL="https://github.com/zzizer/PROJECT-BAIFAM.git"
BACKEND_DIR="$APP_DIR/backend"
FRONTEND_DIR="$APP_DIR/frontend"
BRANCH="main"
LOG_FILE="/var/log/device_setup.log"
DB_NAME="baifam_db"
DB_USER="baifam_user"
DB_PASSWORD=$(openssl rand -hex 16)      
SECRET_KEY=$(openssl rand -hex 32)
EMAIL_HOST="smtp.example.com"
RESPONSE_EMAIL="noreply@example.com"
RESPONSE_EMAIL_PASSWORD=$(openssl rand -hex 16)
FRONTEND_URL="http://$DEVICE_NAME.local"

# ─── Logging ──────────────────────────────────────────────────────
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "Setup started by: $REAL_USER"

# ══════════════════════════════════════════════════════════════════
#  SYSTEM UPDATE
# ══════════════════════════════════════════════════════════════════
log "Updating package lists..."
apt-get update -qq

# ══════════════════════════════════════════════════════════════════
#  INSTALL PACKAGES
# ══════════════════════════════════════════════════════════════════
log "Installing system dependencies..."
apt-get install -y \
    python3-pip python3-venv \
    nginx \
    postgresql postgresql-contrib \
    git \
    nodejs npm \
    avahi-daemon \
    redis-server \
    curl \
    openssl \
    dphys-swapfile

# ══════════════════════════════════════════════════════════════════
#  HOSTNAME
# ══════════════════════════════════════════════════════════════════
CURRENT_HOST=$(hostname)
if [ "$CURRENT_HOST" != "$DEVICE_NAME" ]; then
    log "Setting hostname to $DEVICE_NAME..."
    hostnamectl set-hostname "$DEVICE_NAME"
    # Update /etc/hosts safely — remove old 127.0.1.1 line and replace
    sed -i "/^127\.0\.1\.1/d" /etc/hosts
    echo "127.0.1.1 $DEVICE_NAME" >> /etc/hosts
fi

# ══════════════════════════════════════════════════════════════════
#  AVAHI (mDNS — enables device-name.local)
# ══════════════════════════════════════════════════════════════════
log "Configuring avahi-daemon..."
systemctl enable avahi-daemon
systemctl restart avahi-daemon

# ══════════════════════════════════════════════════════════════════
#  REDIS
# ══════════════════════════════════════════════════════════════════
log "Configuring Redis..."

REDIS_CONF="/etc/redis/redis.conf"

# Bind to localhost only — no external exposure
sed -i 's/^bind .*/bind 127.0.0.1/' "$REDIS_CONF"

# Disable protected-mode (we're binding to localhost, this is safe)
sed -i 's/^protected-mode yes/protected-mode no/' "$REDIS_CONF"

# Persist to disk (RDB snapshot)
grep -q "^save 900 1" "$REDIS_CONF" || echo "save 900 1" >> "$REDIS_CONF"
grep -q "^save 300 10" "$REDIS_CONF" || echo "save 300 10" >> "$REDIS_CONF"

# Set max memory policy to avoid OOM on a Pi
grep -q "^maxmemory-policy" "$REDIS_CONF" \
    || echo "maxmemory-policy allkeys-lru" >> "$REDIS_CONF"
grep -q "^maxmemory " "$REDIS_CONF" \
    || echo "maxmemory 256mb" >> "$REDIS_CONF"

systemctl enable redis-server
systemctl restart redis-server

# Wait for Redis to be ready
log "Waiting for Redis..."
for i in $(seq 1 10); do
    redis-cli ping | grep -q PONG && break
    [ "$i" -eq 10 ] && { log "ERROR: Redis failed to start"; exit 1; }
    sleep 1
done
log "Redis is up."

# ══════════════════════════════════════════════════════════════════
#  CLONE / UPDATE REPOSITORY
# ══════════════════════════════════════════════════════════════════
log "Cloning or updating repository..."

mkdir -p "$APP_PARENT"
chown -R "$REAL_USER:$REAL_USER" "$APP_PARENT"

if [ ! -d "$APP_DIR/.git" ]; then
    sudo -u "$REAL_USER" git clone -b "$BRANCH" "$REPOSITORY_URL" "$APP_DIR"
else
    cd "$APP_DIR"
    sudo -u "$REAL_USER" git pull origin "$BRANCH"
fi

# ══════════════════════════════════════════════════════════════════
#  DEVICE IDENTITY (no hardcoded values)
# ══════════════════════════════════════════════════════════════════
log "Detecting device identity..."

# Raspberry Pi serial from cpuinfo; falls back to machine-id
DEVICE_SERIAL=$(grep -oP 'Serial\s*:\s*\K[0-9a-f]+' /proc/cpuinfo 2>/dev/null \
    || cat /etc/machine-id 2>/dev/null \
    || uuidgen)

# Detect hardware model (Pi 4, Pi 5, or generic)
DEVICE_MODEL_RAW=$(grep -oP 'Model\s*:\s*\K.+' /proc/cpuinfo 2>/dev/null \
    || echo "Generic-Linux")
# Sanitise to a single token
DEVICE_MODEL=$(echo "$DEVICE_MODEL_RAW" | tr ' ' '-' | tr -cd '[:alnum:]-')

log "Serial: $DEVICE_SERIAL | Model: $DEVICE_MODEL"

# ══════════════════════════════════════════════════════════════════
#  BACKEND — virtualenv & .env
# ══════════════════════════════════════════════════════════════════
log "Setting up backend..."
cd "$BACKEND_DIR"

ENV_FILE="$BACKEND_DIR/.env"

echo "DB_USER='$DB_USER'" 
echo "DB_PASSWORD='$DB_PASSWORD'"
echo "DB_NAME='$DB_NAME'"

if [ ! -f "$ENV_FILE" ]; then
    log "Creating backend .env..."

    # URL-encode the DB password for the DATABASE_URL
    # Python is already available and handles all special chars correctly
    DB_PASSWORD_ENCODED=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" \
        "$DB_PASSWORD")

    cat > "$ENV_FILE" <<EOF
SECRET_KEY=$SECRET_KEY
DEBUG=False
ALLOWED_HOSTS=*

DATABASE_URL=postgres://$DB_USER:${DB_PASSWORD_ENCODED}@localhost:5432/$DB_NAME

EMAIL_HOST=$EMAIL_HOST
RESPONSE_EMAIL_PASSWORD=$RESPONSE_EMAIL_PASSWORD
RESPONSE_EMAIL=$RESPONSE_EMAIL

REDIS_URL=redis://127.0.0.1:6379/0
CELERY_BROKER_URL=redis://127.0.0.1:6379/1
CELERY_RESULT_BACKEND=redis://127.0.0.1:6379/2

FRONTEND_URL=$FRONTEND_URL

DEVICE_SERIAL_NUMBER=$DEVICE_SERIAL
DEVICE_MODEL=$DEVICE_MODEL
HARDWARE_VERSION=1.1
FIRMWARE_VERSION=1.0.0
FINGERPRINT_TEMPLATE_SIZE=1000
EOF

    # Lock down .env — readable only by owner
    chmod 600 "$ENV_FILE"
    chown "$REAL_USER:$REAL_USER" "$ENV_FILE"
    log "Backend .env created and locked (600)."
else
    log "Backend .env already exists — keeping existing values."
fi

# ─── Python virtualenv ────────────────────────────────────────────
if [ ! -d "$BACKEND_DIR/venv" ]; then
    log "Creating Python virtualenv..."
    sudo -u "$REAL_USER" python3 -m venv "$BACKEND_DIR/venv"
fi

sudo -u "$REAL_USER" "$BACKEND_DIR/venv/bin/pip" install --upgrade pip --quiet
sudo -u "$REAL_USER" "$BACKEND_DIR/venv/bin/pip" install -r "$BACKEND_DIR/requirements.txt" --quiet

# ══════════════════════════════════════════════════════════════════
#  POSTGRESQL
# ══════════════════════════════════════════════════════════════════
log "Setting up PostgreSQL..."

systemctl enable postgresql
systemctl start postgresql

# Wait for PostgreSQL to be ready
for i in $(seq 1 10); do
    sudo -u postgres psql -c '\q' 2>/dev/null && break
    [ "$i" -eq 10 ] && { log "ERROR: PostgreSQL failed to start"; exit 1; }
    sleep 1
done

# Create DB user if missing
if ! sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c \
        "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    log "PostgreSQL user '$DB_USER' created."
fi

# Create database if missing
if ! sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
    log "PostgreSQL database '$DB_NAME' created."
fi

# Grant privileges
sudo -u postgres psql -c \
    "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

# ─── Django migrations ────────────────────────────────────────────
log "Running Django migrations..."
cd "$BACKEND_DIR"
source venv/bin/activate

python manage.py migrate --noinput
log "Migrations complete."

python manage.py collectstatic --noinput
log "Static files collected."

deactivate

# ══════════════════════════════════════════════════════════════════
#  FRONTEND
# ══════════════════════════════════════════════════════════════════
log "Setting up frontend..."
cd "$FRONTEND_DIR"

FRONTEND_ENV="$FRONTEND_DIR/.env"

if [ ! -f "$FRONTEND_ENV" ]; then
    log "Creating frontend .env..."
    cat > "$FRONTEND_ENV" <<EOF
NEXT_PUBLIC_API_URL=/api
EOF
else
    log "Updating frontend .env API URL..."
    if grep -q "NEXT_PUBLIC_API_URL" "$FRONTEND_ENV"; then
        sed -i 's|NEXT_PUBLIC_API_URL=.*|NEXT_PUBLIC_API_URL=/api|' "$FRONTEND_ENV"
    else
        echo "NEXT_PUBLIC_API_URL=/api" >> "$FRONTEND_ENV"
    fi
fi

if [ -f "package.json" ]; then
    log "Installing frontend dependencies..."

    sudo -u "$REAL_USER" npm install --silent --no-audit --no-fund

    log "Building frontend (low memory mode)..."

    export NODE_OPTIONS="--max-old-space-size=512"

    sudo -u "$REAL_USER" npm run build || {
        log "Build failed, retrying with more memory..."

        export NODE_OPTIONS="--max-old-space-size=768"
        sudo -u "$REAL_USER" npm run build
    }

    log "Exporting static site..."
    sudo -u "$REAL_USER" npm run export

else
    log "No package.json found — skipping frontend build."
fi

# ══════════════════════════════════════════════════════════════════
#  NGINX — listen on all interfaces (LAN accessible)
# ══════════════════════════════════════════════════════════════════
log "Configuring Nginx..."

NGINX_CONF="/etc/nginx/sites-available/baifam"

cat > "$NGINX_CONF" <<EOF
server {
    # Listen on all interfaces so any device on the same LAN can reach it
    listen 80;

    # Match both mDNS hostname and any IP on the local network
    server_name $DEVICE_NAME.local _;

    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    # Static frontend (Next.js export)
    location / {
        root $FRONTEND_DIR/out;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # Django REST API
    location /api/ {
        proxy_pass http://127.0.0.1:8000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }

    # Django admin
    location /admin/ {
        proxy_pass http://127.0.0.1:8000/admin/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # API docs
    location /docs/ {
        proxy_pass http://127.0.0.1:8000/docs/;
        proxy_set_header Host \$host;
    }

    # Django Channels / WebSockets
    location /ws/ {
        proxy_pass http://127.0.0.1:8000/ws/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
    }

    # Flower (Celery monitoring UI) — restrict to LAN use
    location /flower/ {
        proxy_pass http://127.0.0.1:5555/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        # Optional: lock Flower behind basic auth in production
        # auth_basic "Flower";
        # auth_basic_user_file /etc/nginx/.htpasswd;
    }

    # Static & media files served by Nginx directly
    location /static/ {
        alias $BACKEND_DIR/staticfiles/;
    }

    location /media/ {
        alias $BACKEND_DIR/media/;
    }

    client_max_body_size 20M;
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/baifam

# Remove default site if still linked
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
log "Nginx configured."

# ══════════════════════════════════════════════════════════════════
#  SYSTEMD SERVICES
# ══════════════════════════════════════════════════════════════════
log "Creating systemd service units..."

VENV_BIN="$BACKEND_DIR/venv/bin"

# ─── 1. Daphne (ASGI — Django + Channels) ────────────────────────
cat > /etc/systemd/system/baifam-backend.service <<EOF
[Unit]
Description=BAIFAM Django/Channels Backend (Daphne ASGI)
After=network.target postgresql.service redis-server.service
Requires=postgresql.service redis-server.service

[Service]
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$BACKEND_DIR/.env
ExecStart=$VENV_BIN/daphne core.asgi:application \
    --bind 127.0.0.1 \
    --port 8000
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=baifam-backend

[Install]
WantedBy=multi-user.target
EOF

# ─── 2. Celery Worker ─────────────────────────────────────────────
cat > /etc/systemd/system/baifam-worker.service <<EOF
[Unit]
Description=BAIFAM Celery Worker
After=network.target redis-server.service baifam-backend.service
Requires=redis-server.service

[Service]
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$BACKEND_DIR/.env
ExecStart=$VENV_BIN/celery -A core worker \
    --loglevel=info \
    --concurrency=2 \
    --max-tasks-per-child=200
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=baifam-worker

[Install]
WantedBy=multi-user.target
EOF

# ─── 3. Celery Beat (periodic tasks scheduler) ────────────────────
cat > /etc/systemd/system/baifam-beat.service <<EOF
[Unit]
Description=BAIFAM Celery Beat Scheduler
After=network.target redis-server.service baifam-backend.service
Requires=redis-server.service

[Service]
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$BACKEND_DIR/.env
ExecStart=$VENV_BIN/celery -A core beat \
    --loglevel=info \
    --scheduler django_celery_beat.schedulers:DatabaseScheduler
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=baifam-beat

[Install]
WantedBy=multi-user.target
EOF

# ─── 4. Flower (Celery monitoring UI) ────────────────────────────
cat > /etc/systemd/system/baifam-flower.service <<EOF
[Unit]
Description=BAIFAM Celery Flower Monitor
After=network.target redis-server.service baifam-worker.service
Requires=redis-server.service

[Service]
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$BACKEND_DIR/.env
ExecStart=$VENV_BIN/celery -A core flower \
    --port=5555 \
    --url-prefix=flower \
    --broker=\${CELERY_BROKER_URL}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=baifam-flower

[Install]
WantedBy=multi-user.target
EOF

# ══════════════════════════════════════════════════════════════════
#  START ALL SERVICES
# ══════════════════════════════════════════════════════════════════
log "Enabling and starting all services..."

systemctl daemon-reload

SERVICES=(
    postgresql
    redis-server
    baifam-backend
    baifam-worker
    baifam-beat
    baifam-flower
    nginx
)

for svc in "${SERVICES[@]}"; do
    systemctl enable "$svc"
    systemctl restart "$svc"
    # Give daphne a moment before starting dependants
    [ "$svc" = "baifam-backend" ] && sleep 3
    log "  ✔ $svc started"
done

# ══════════════════════════════════════════════════════════════════
#  HEALTH CHECK
# ══════════════════════════════════════════════════════════════════
log "Running health checks..."
sleep 5

ALL_OK=true
for svc in "${SERVICES[@]}"; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [ "$STATUS" != "active" ]; then
        log "  ✗ $svc is $STATUS — check: journalctl -u $svc -n 50"
        ALL_OK=false
    else
        log "  ✔ $svc is active"
    fi
done

# ══════════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════════
log "══════════════════════════════════════════"
log "  SETUP COMPLETE"
log ""
log "  Access via mDNS:  http://$DEVICE_NAME.local"
log "  Access via IP:    http://$(hostname -I | awk '{print $1}')"
log "  Flower:           http://$(hostname -I | awk '{print $1}')/flower/"
log "  Admin:            http://$(hostname -I | awk '{print $1}')/admin/"
log ""

if [ "$ALL_OK" = false ]; then
    log "  ⚠  One or more services failed. Review logs above."
else
    log "  All services running."
fi

log "══════════════════════════════════════════"