#!/bin/bash
# Script para criar stack com Redis, PostgreSQL e Evolution API no Portainer
# Com suporte a edição no Portainer

# Cores para exibição
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações
PORTAINER_URL="https://painel.trafegocomia.com"
PORTAINER_USER="admin"
PORTAINER_PASSWORD="fpU6TW3Dg7ulCL+k"
DOMAIN="trafegocomia.com"
STACK_NAME="evolution-stack"
ENDPOINT_ID=2  # ID do endpoint "local" identificado na sua instalação do Portainer

# Função para exibir mensagens
log() {
  echo -e "${2:-$GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Criar conteúdo do docker-compose.yml
cat > ./docker-compose.yml << EOF
version: '3.7'
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

  evolution:
    image: atendai/evolution-api:latest
    volumes:
      - evolution_instances:/evolution/instances
    networks:
      - GrowthNet
    environment:
      - SERVER_URL=https://api.${DOMAIN}
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
      - traefik.http.routers.evolution.rule=Host(\`api.${DOMAIN}\`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.priority=1
      - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
      - traefik.http.routers.evolution.service=evolution
      - traefik.http.services.evolution.loadbalancer.server.port=8080

volumes:
  redis_data:
    external: true
  postgres_data:
    external: true
  evolution_instances:
    external: true

networks:
  GrowthNet:
    external: true
EOF

# Criar volumes se não existirem
log "Verificando e criando volumes..." "$BLUE"
docker volume create redis_data 2>/dev/null || log "Volume redis_data já existe." "$YELLOW"
docker volume create postgres_data 2>/dev/null || log "Volume postgres_data já existe." "$YELLOW"
docker volume create evolution_instances 2>/dev/null || log "Volume evolution_instances já existe." "$YELLOW"

# Criar rede se não existir
log "Verificando e criando rede..." "$BLUE"
docker network create --driver overlay GrowthNet 2>/dev/null || log "Rede GrowthNet já existe." "$YELLOW"

# Obter token de autenticação do Portainer
log "Autenticando no Portainer..." "$BLUE"
AUTH_RESPONSE=$(curl -k -s -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"$PORTAINER_USER\",\"Password\":\"$PORTAINER_PASSWORD\"}")

JWT=$(echo $AUTH_RESPONSE | grep -o '"jwt":"[^"]*"' | cut -d'"' -f4)

if [ -z "$JWT" ]; then
  log "Falha na autenticação do Portainer" "$RED"
  exit 1
fi

log "Autenticação bem-sucedida!" "$GREEN"

# Primeiro, verificar se o stack já existe para removê-lo se necessário
log "Verificando se o stack já existe..." "$BLUE"
STACKS_RESPONSE=$(curl -k -s -X GET "$PORTAINER_URL/api/stacks" \
  -H "Authorization: Bearer $JWT")

# Extrair ID do stack, se existir
STACK_ID=$(echo $STACKS_RESPONSE | jq -r ".[] | select(.Name == \"$STACK_NAME\") | .Id")

if [ ! -z "$STACK_ID" ]; then
  log "Stack $STACK_NAME já existe com ID $STACK_ID. Removendo..." "$YELLOW"
  curl -k -s -X DELETE "$PORTAINER_URL/api/stacks/$STACK_ID" \
    -H "Authorization: Bearer $JWT"
  
  sleep 5 # Aguardar remoção
fi

# Criar um arquivo temporário com o conteúdo do docker-compose
STACK_CONTENT=$(cat ./docker-compose.yml)

# Criar o stack no Portainer usando o endpoint correto (2)
log "Criando stack $STACK_NAME no Portainer..." "$BLUE"

# Enviar o conteúdo do docker-compose para o Portainer
RESPONSE=$(curl -k -s -X POST "$PORTAINER_URL/api/stacks" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{
    \"Name\": \"$STACK_NAME\",
    \"StackFileContent\": $(echo "$STACK_CONTENT" | jq -Rs .),
    \"SwarmID\": \"default\",
    \"Env\": [{\"name\":\"DOMAIN\", \"value\":\"$DOMAIN\"}],
    \"EndpointId\": $ENDPOINT_ID,
    \"FromAppTemplate\": false
  }")

# Verificar resposta
echo "$RESPONSE" > /tmp/stack_response.json

if echo "$RESPONSE" | grep -q "error"; then
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.message // "Erro desconhecido"')
  log "Erro ao criar stack: $ERROR_MSG" "$RED"
  exit 1
fi

# Verificar se o stack foi criado
NEW_STACK_ID=$(echo "$RESPONSE" | jq -r '.Id // ""')

if [ -z "$NEW_STACK_ID" ] || [ "$NEW_STACK_ID" == "null" ]; then
  log "Falha ao obter ID do stack criado" "$RED"
  exit 1
fi

log "Stack $STACK_NAME criado com sucesso! ID: $NEW_STACK_ID" "$GREEN"
log "Você pode gerenciá-lo pelo Portainer em: $PORTAINER_URL/#/stacks/$NEW_STACK_ID" "$GREEN"

# Salvar credenciais
mkdir -p /root/.credentials
chmod 700 /root/.credentials

cat > /root/.credentials/evolution.txt << EOF
Evolution API Information
URL: https://api.$DOMAIN
API Key: 2dc7b3194ce0704b12f68305f1904ca4
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF
chmod 600 /root/.credentials/evolution.txt

log "Credenciais salvas em: /root/.credentials/evolution.txt" "$GREEN"
log "Instalação concluída!" "$GREEN"
