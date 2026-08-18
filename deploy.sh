#!/bin/bash

set -e

CONFIG_FILE="deploy.json"

echo ""
echo "======================================"
echo "        🚀 Deployment Tool"
echo "======================================"
echo ""

# --------------------------------------------------
# Helper
# --------------------------------------------------

ask() {
    local prompt="$1"
    local default="$2"

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " value
        echo "${value:-$default}"
    else
        read -p "$prompt: " value
        echo "$value"
    fi
}

# --------------------------------------------------
# First time setup
# --------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then

    echo "No deploy.json found."
    echo ""
    echo "Let's configure your deployment."
    echo ""

    echo "What do you want to deploy?"
    echo "1) Frontend"
    echo "2) Backend"
    echo ""

    read -p "Select [1/2]: " TYPE_CHOICE

    case "$TYPE_CHOICE" in
        1)
            TYPE="frontend"
            ;;
        2)
            TYPE="backend"
            ;;
        *)
            echo "❌ Invalid selection."
            exit 1
            ;;
    esac

    echo ""

    HOST=$(ask "Server Host / IP" "")
    SSH_USER=$(ask "SSH User" "root")

    echo ""
    echo "Select Authentication Method:"
    echo "1) SSH Key"
    echo "2) Password"
    read -p "Select [1/2]: " AUTH_CHOICE

    case "$AUTH_CHOICE" in
        1)
            AUTH_TYPE="key"
            SSH_KEY=$(ask "SSH Key Path" "$HOME/.ssh/id_rsa")
            SSH_PASS=""
            ;;
        2)
            AUTH_TYPE="password"
            SSH_KEY=""
            read -sp "SSH Password: " SSH_PASS
            echo ""
            ;;
        *)
            echo "❌ Invalid selection."
            exit 1
            ;;
    esac

    echo ""

    REPOSITORY=$(ask "GitHub Repository URL" "")
    BRANCH=$(ask "Git Branch" "main")

    echo ""

    DEPLOY_PATH=$(ask "Deploy Path" "/var/www/project")

    echo ""

    read -p "Does server use Docker? [y/N]: " DOCKER_INPUT

    if [[ "$DOCKER_INPUT" =~ ^[Yy]$ ]]; then
        DOCKER=true

        COMPOSE_FILE=$(ask "Docker Compose File" "docker-compose.yml")
        DOCKER_SERVICE=$(ask "Docker Service (optional)" "")
    else
        DOCKER=false

        PM2_NAME=$(ask "PM2 App Name" "$TYPE")
        PORT=$(ask "Application Port" "3000")

        if [ "$TYPE" = "frontend" ]; then
            BUILD_COMMAND=$(ask "Build Command" "npm run build")
            START_COMMAND=$(ask "Start Command" "npm run start")
        else
            BUILD_COMMAND=$(ask "Build Command" "npm run build")
            START_COMMAND=$(ask "Start Command" "npm run start")
        fi
    fi

    echo ""

    echo "Creating $CONFIG_FILE..."

    # Generate JSON (Secrets like passwords are NEVER saved in JSON)
    if [ "$DOCKER" = true ]; then

        cat > "$CONFIG_FILE" <<EOF
{
  "type": "$TYPE",
  "host": "$HOST",
  "user": "$SSH_USER",
  "authType": "$AUTH_TYPE",
  "sshKey": "$SSH_KEY",
  "repository": "$REPOSITORY",
  "branch": "$BRANCH",
  "deployPath": "$DEPLOY_PATH",
  "docker": true,
  "composeFile": "$COMPOSE_FILE",
  "dockerService": "$DOCKER_SERVICE"
}
EOF

    else

        cat > "$CONFIG_FILE" <<EOF
{
  "type": "$TYPE",
  "host": "$HOST",
  "user": "$SSH_USER",
  "authType": "$AUTH_TYPE",
  "sshKey": "$SSH_KEY",
  "repository": "$REPOSITORY",
  "branch": "$BRANCH",
  "deployPath": "$DEPLOY_PATH",
  "docker": false,
  "pm2Name": "$PM2_NAME",
  "port": "$PORT",
  "buildCommand": "$BUILD_COMMAND",
  "startCommand": "$START_COMMAND"
}
EOF

    fi

    echo "✅ deploy.json created."
    echo ""

    # Ensure deploy.json is in .gitignore so it never gets pushed to GitHub
    if [ -f ".gitignore" ]; then
        if ! grep -qs "^deploy\.json" .gitignore; then
            echo "" >> .gitignore
            echo "deploy.json" >> .gitignore
            echo "🔒 Added deploy.json to .gitignore."
        fi
    else
        echo "deploy.json" > .gitignore
        echo "🔒 Created .gitignore and added deploy.json."
    fi
    echo ""

else

    echo "📄 Existing deploy.json found."
    echo "Using existing configuration."
    echo ""

    # Ensure deploy.json is in .gitignore
    if [ -f ".gitignore" ]; then
        if ! grep -qs "^deploy\.json" .gitignore; then
            echo "" >> .gitignore
            echo "deploy.json" >> .gitignore
            echo "🔒 Added deploy.json to .gitignore."
        fi
    fi

fi


# --------------------------------------------------
# Read configuration
# --------------------------------------------------

TYPE=$(jq -r '.type' "$CONFIG_FILE")
HOST=$(jq -r '.host' "$CONFIG_FILE")
SSH_USER=$(jq -r '.user' "$CONFIG_FILE")
AUTH_TYPE=$(jq -r '.authType // "key"' "$CONFIG_FILE")
SSH_KEY=$(jq -r '.sshKey // ""' "$CONFIG_FILE")
REPOSITORY=$(jq -r '.repository' "$CONFIG_FILE")
BRANCH=$(jq -r '.branch' "$CONFIG_FILE")
DEPLOY_PATH=$(jq -r '.deployPath' "$CONFIG_FILE")
DOCKER=$(jq -r '.docker' "$CONFIG_FILE")


# --------------------------------------------------
# Validate configuration
# --------------------------------------------------

if [ "$HOST" = "null" ] || [ -z "$HOST" ]; then
    echo "❌ Host is missing."
    exit 1
fi

if [ "$REPOSITORY" = "null" ] || [ -z "$REPOSITORY" ]; then
    echo "❌ Repository is missing."
    exit 1
fi

if [ "$AUTH_TYPE" = "key" ]; then
    if [ "$SSH_KEY" = "null" ] || [ -z "$SSH_KEY" ] || [ ! -f "${SSH_KEY/#\~/$HOME}" ]; then
        echo "❌ SSH key not found: $SSH_KEY"
        exit 1
    fi
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
elif [ "$AUTH_TYPE" = "password" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo "❌ 'sshpass' utility is not installed. Please install sshpass for password authentication."
        echo "   macOS: brew install hudochenkov/sshpass/sshpass"
        echo "   Linux: sudo apt install sshpass"
        exit 1
    fi
    if [ -z "$SSH_PASS" ]; then
        read -sp "🔑 Enter SSH Password for $SSH_USER@$HOST: " SSH_PASS
        echo ""
    fi
    if [ -z "$SSH_PASS" ]; then
        echo "❌ SSH password cannot be empty."
        exit 1
    fi
else
    echo "❌ Invalid authentication method."
    exit 1
fi


# --------------------------------------------------
# SSH command helper
# --------------------------------------------------

run_ssh() {
    if [ "$AUTH_TYPE" = "password" ]; then
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$HOST" "$@"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$HOST" "$@"
    fi
}


echo "======================================"
echo "Deployment Information"
echo "======================================"
echo "Type       : $TYPE"
echo "Server     : $SSH_USER@$HOST"
echo "Auth Type  : $AUTH_TYPE"
echo "Repository : $REPOSITORY"
echo "Branch     : $BRANCH"
echo "Path       : $DEPLOY_PATH"
echo "Docker     : $DOCKER"
echo "======================================"
echo ""


# --------------------------------------------------
# Test SSH
# --------------------------------------------------

echo "🔌 Testing SSH connection..."

run_ssh "echo 'SSH connection successful'"

echo ""


# --------------------------------------------------
# Docker Deployment
# --------------------------------------------------

if [ "$DOCKER" = "true" ]; then

    COMPOSE_FILE=$(jq -r '.composeFile' "$CONFIG_FILE")
    DOCKER_SERVICE=$(jq -r '.dockerService' "$CONFIG_FILE")

    echo "🐳 Docker deployment started..."
    echo ""

    run_ssh bash <<EOF

set -e

echo "📁 Preparing deployment directory..."

mkdir -p "$DEPLOY_PATH"

cd "$DEPLOY_PATH"

if [ -d ".git" ]; then

    echo "🔄 Updating repository..."

    git fetch origin
    git checkout "$BRANCH"
    git reset --hard "origin/$BRANCH"

else

    echo "📦 Cloning repository..."

    git clone --branch "$BRANCH" "$REPOSITORY" .

fi

echo "🐳 Building Docker containers..."

if [ -n "$DOCKER_SERVICE" ] && [ "$DOCKER_SERVICE" != "null" ]; then

    docker compose -f "$COMPOSE_FILE" down

    docker compose -f "$COMPOSE_FILE" up -d --build "$DOCKER_SERVICE"

else

    docker compose -f "$COMPOSE_FILE" down

    docker compose -f "$COMPOSE_FILE" up -d --build

fi

echo ""
echo "✅ Docker deployment completed."

EOF


# --------------------------------------------------
# Non Docker Deployment
# --------------------------------------------------

else

    PM2_NAME=$(jq -r '.pm2Name' "$CONFIG_FILE")
    PORT=$(jq -r '.port' "$CONFIG_FILE")
    BUILD_COMMAND=$(jq -r '.buildCommand' "$CONFIG_FILE")
    START_COMMAND=$(jq -r '.startCommand' "$CONFIG_FILE")


    echo "📦 Non-Docker deployment started..."
    echo ""

    run_ssh bash <<EOF

set -e

echo "📁 Preparing deployment directory..."

mkdir -p "$DEPLOY_PATH"

cd "$DEPLOY_PATH"

if [ -d ".git" ]; then

    echo "🔄 Updating repository..."

    git fetch origin

    git checkout "$BRANCH"

    git reset --hard "origin/$BRANCH"

else

    echo "📦 Cloning repository..."

    git clone --branch "$BRANCH" "$REPOSITORY" .

fi


echo "📦 Installing dependencies..."

npm install


echo "🔨 Building application..."

$BUILD_COMMAND


echo "🚀 Starting application with PM2..."

if pm2 describe "$PM2_NAME" > /dev/null 2>&1; then

    echo "🔄 Restarting existing PM2 process..."

    PORT="$PORT" pm2 restart "$PM2_NAME" --update-env

else

    echo "🆕 Starting new PM2 process..."

    PORT="$PORT" pm2 start "$START_COMMAND" \
        --name "$PM2_NAME"

fi


pm2 save

echo ""
echo "======================================"
echo "✅ Deployment completed successfully!"
echo "======================================"

EOF

fi


echo ""
echo "🎉 Deployment finished!"
echo ""
