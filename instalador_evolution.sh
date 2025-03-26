#!/bin/bash
# Script para instalação via API do Portainer (ignorando verificação SSL)

# Cores para exibição
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurações
PORTAINER_URL="https://painel.trafegocomia.com"
PORTAINER_USER="admin"
PORTAINER_PASSWORD="fpU6TW3Dg7ulCL+k"
DOMAIN="trafegocomia.com"
TEMP_DIR="/tmp/install-tmp"

# Criar diretório temporário
mkdir -p "$TEMP_DIR"

# Funções de log
log() {
  echo -e "${2:-$GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Autenticar
log "Autenticando no Portainer..." "$BLUE"
AUTH_RESPONSE=$(curl -k -s -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"$PORTAINER_USER\",\"Password\":\"$PORTAINER_PASSWORD\"}")

# Extrair token
JWT=$(echo $AUTH_RESPONSE | grep -o '"jwt":"[^"]*"' | cut -d'"' -f4)

if [ -z "$JWT" ]; then
  log "Falha na autenticação" "$RED"
  exit 1
fi

log "Autenticação bem-sucedida!" "$GREEN"

# Criar rede e volumes
log "Criando rede GrowthNet..." "$BLUE"
docker network create --driver overlay GrowthNet 2>/dev/null || log "Rede já existe" "$YELLOW"

log "Criando volumes..." "$BLUE"
docker volume create redis_data 2>/dev/null || log "Volume redis_data já existe" "$YELLOW"
docker volume create postgres_data 2>/dev/null || log "Volume postgres_data já existe" "$YELLOW"
docker volume create evolution_instances 2>/dev/null || log "Volume evolution_instances já existe" "$YELLOW"

# Criar stacks
create_stack() {
  local name=$1
  local file=$2
  log "Criando stack $name..." "$BLUE"
  
  # Preparar arquivo de stack
  echo "$file" > "$TEMP_DIR/$name.yml"
  
  # Criar stack via API
  RESPONSE=$(curl -k -s -X POST "$PORTAINER_URL/api/stacks" \
    -H "Authorization: Bearer $JWT" \
    -F "Name=$name" \
    -F "SwarmID=default" \
    -F "file=@$TEMP_DIR/$name.yml")
    
  echo "$RESPONSE" > "$TEMP_DIR/${name}_response.json"
  
  if echo "$RESPONSE" | grep -q "error"; then
    log "Erro ao criar stack $name" "$RED"
    return 1
  fi
  
  log "Stack $name criado com sucesso!" "$GREEN"
}

# Redis stack
REDIS_STACK=$(cat <<EOF
version: "3.7"
services:
  redis:
    image: redis:latest
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
volumes:
  redis_data:
    external: true
networks:
  GrowthNet:
    external: true
EOF
)

# PostgreSQL stack
POSTGRES_STACK=$(cat <<EOF
version: "3.7"
services:
  postgres:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=b2ecbaa44551df03fa3793b38091cff7
      - POSTGRES_USER=postgres
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
volumes:
  postgres_data:
    external: true
networks:
  GrowthNet:
    external: true
EOF
)

# Evolution stack
EVOLUTION_STACK=$(cat <<EOF
version: "3.7"
services:
  evolution:
    image: atendai/evolution-api:latest
    volumes:
      - evolution_instances:/evolution/instances
    networks:
      - GrowthNet
    environment:
      - SERVER_URL=https://api.$DOMAIN
      - AUTHENTICATION_API_KEY=2dc7b3194ce0704b12f68305f1904ca4
      - AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
      - DEL_INSTANCE=false
      - QRCODE_LIMIT=1902
      - LANGUAGE=pt-BR
      - CONFIG_SESSION_PHONE_VERSION=2.3000.1019780779
      - CONFIG_SESSION_PHONE_CLIENT=GrowthTap
      - CONFIG_SESSION_PHONE_NAME=Chrome
      - DATABASE_ENABLED=true
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
      - DATABASE_CONNECTION_CLIENT_NAME=evolution
      - DATABASE_SAVE_DATA_INSTANCE=true
      - DATABASE_SAVE_DATA_NEW_MESSAGE=true
      - DATABASE_SAVE_MESSAGE_UPDATE=true
      - DATABASE_SAVE_DATA_CONTACTS=true
      - DATABASE_SAVE_DATA_CHATS=true
      - DATABASE_SAVE_DATA_LABELS=true
      - DATABASE_SAVE_DATA_HISTORIC=true
      - OPENAI_ENABLED=true
      - DIFY_ENABLED=true
      - TYPEBOT_ENABLED=true
      - TYPEBOT_API_VERSION=latest
      - CHATWOOT_ENABLED=true
      - CHATWOOT_MESSAGE_READ=true
      - CHATWOOT_MESSAGE_DELETE=true
      - CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/chatwoot?sslmode=disable
      - CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=false
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://redis:6379/8
      - CACHE_REDIS_PREFIX_KEY=evolution
      - CACHE_REDIS_SAVE_INSTANCES=false
      - CACHE_LOCAL_ENABLED=false
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      labels:
      - traefik.enable=true
      - traefik.http.routers.evolution.rule=Host(\`api.$DOMAIN\`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.priority=1
      - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
      - traefik.http.routers.evolution.service=evolution
      - traefik.http.services.evolution.loadbalancer.server.port=8080
volumes:
  evolution_instances:
    external: true
networks:
  GrowthNet:
    external: true
EOF
)

# Criar stacks
create_stack "redis" "$REDIS_STACK"
create_stack "postgres" "$POSTGRES_STACK" 
create_stack "evolution" "$EVOLUTION_STACK"

# Salvar credenciais
mkdir -p /root/.credentials
chmod 700 /root/.credentials

cat > /root/.credentials/evolution.txt << EOF
Evolution API Information
URL: https://api.$DOMAIN
API Key: 2dc7b3194ce0704b12f68305f1904ca4
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF

log "Instalação concluída!" "$GREEN"
log "Acesse a Evolution API em: https://api.$DOMAIN" "$GREEN"
log "Credenciais salvas em: /root/.credentials/evolution.txt" "$GREEN"
