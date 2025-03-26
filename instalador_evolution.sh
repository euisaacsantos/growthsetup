#!/bin/bash
# Script para criar stack com Redis, PostgreSQL e Evolution API no Portainer
# Com suporte a edição no Portainer

# Cores para exibição
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações padrão
PORTAINER_URL=""
PORTAINER_USER=""
PORTAINER_PASSWORD=""
DOMAIN=""
STACK_NAME="evolution-stack"
ENDPOINT_ID=2  # ID do endpoint "local"
DEBUG=false

# Função para exibir mensagens
log() {
  echo -e "${2:-$GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Função para exibir uso
usage() {
  echo "Uso: $0 [opções]"
  echo "Opções:"
  echo "  --portainer-url URL      URL do Portainer (ex: https://painel.example.com)"
  echo "  --portainer-user USER    Usuário do Portainer"
  echo "  --portainer-password PWD Senha do Portainer"
  echo "  --domain DOMAIN          Domínio principal (ex: example.com)"
  echo "  --stack-name NAME        Nome do stack (padrão: evolution-stack)"
  echo "  --endpoint-id ID         ID do endpoint no Portainer (padrão: 2)"
  echo "  --debug                  Ativar modo debug"
  echo "  --help                   Mostrar esta ajuda"
  exit 1
}

# Processar argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --portainer-url)
      PORTAINER_URL="$2"
      shift 2
      ;;
    --portainer-user)
      PORTAINER_USER="$2"
      shift 2
      ;;
    --portainer-password)
      PORTAINER_PASSWORD="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --endpoint-id)
      ENDPOINT_ID="$2"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --help)
      usage
      ;;
    *)
      echo "Opção desconhecida: $1"
      usage
      ;;
  esac
done

# Verificar argumentos obrigatórios
if [ -z "$PORTAINER_URL" ] || [ -z "$PORTAINER_USER" ] || [ -z "$PORTAINER_PASSWORD" ] || [ -z "$DOMAIN" ]; then
  log "Argumentos obrigatórios faltando!" "$RED"
  usage
fi

# Criar conteúdo do docker-compose.yml
log "Gerando arquivo docker-compose.yml..." "$BLUE"
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
docker volume create redis_data
docker volume create postgres_data
docker volume create evolution_instances

# Criar rede se não existir
log "Verificando e criando rede..." "$BLUE"
docker network create --driver overlay GrowthNet 2>/dev/null || log "Rede GrowthNet já existe." "$YELLOW"

# Obter token de autenticação do Portainer
log "Autenticando no Portainer..." "$BLUE"
AUTH_RESPONSE=$(curl -k -s -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"$PORTAINER_USER\",\"Password\":\"$PORTAINER_PASSWORD\"}")

if [ "$DEBUG" = true ]; then
  echo "Resposta de autenticação: $AUTH_RESPONSE"
fi

JWT=$(echo $AUTH_RESPONSE | grep -o '"jwt":"[^"]*"' | cut -d'"' -f4)

if [ -z "$JWT" ]; then
  log "Falha na autenticação do Portainer" "$RED"
  exit 1
fi

log "Autenticação bem-sucedida!" "$GREEN"

# Verificar se o stack já existe para removê-lo se necessário
log "Verificando se o stack já existe..." "$BLUE"
STACKS_RESPONSE=$(curl -k -s -X GET "$PORTAINER_URL/api/stacks" \
  -H "Authorization: Bearer $JWT")

if [ "$DEBUG" = true ]; then
  echo "Resposta de stacks: $STACKS_RESPONSE"
fi

# Extrair ID do stack, se existir
STACK_ID=$(echo $STACKS_RESPONSE | jq -r ".[] | select(.Name == \"$STACK_NAME\") | .Id")

if [ ! -z "$STACK_ID" ] && [ "$STACK_ID" != "null" ]; then
  log "Stack $STACK_NAME já existe com ID $STACK_ID. Removendo..." "$YELLOW"
  REMOVE_RESPONSE=$(curl -k -s -X DELETE "$PORTAINER_URL/api/stacks/$STACK_ID" \
    -H "Authorization: Bearer $JWT")
  
  if [ "$DEBUG" = true ]; then
    echo "Resposta de remoção: $REMOVE_RESPONSE"
  fi
  
  sleep 5 # Aguardar remoção
fi

# Alternativa: Usar docker stack deploy (mais confiável)
log "Usando docker stack deploy para criar o stack..." "$BLUE"
docker stack deploy -c ./docker-compose.yml "$STACK_NAME"

if [ $? -eq 0 ]; then
  log "Stack $STACK_NAME criado com sucesso usando docker stack deploy!" "$GREEN"
else
  log "Falha ao criar o stack usando docker stack deploy!" "$RED"
  exit 1
fi

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
log "Você pode gerenciar o stack pelo Portainer em: $PORTAINER_URL" "$GREEN"
