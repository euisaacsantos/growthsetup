#!/bin/bash
# Script para instalar Redis, PostgreSQL e Evolution API via API do Portainer

# Cores para melhor visualização
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variáveis globais
PORTAINER_URL=""
PORTAINER_USER=""
PORTAINER_PASSWORD=""
DOMAIN=""
AUTH_TOKEN=""
TEMP_DIR="/tmp/portainer-api-install"

# Função para exibir mensagens
log() {
  local msg="$1"
  local color="${2:-$GREEN}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${color}[${timestamp}] $msg${NC}"
}

# Função para exibir uso
usage() {
  echo "Uso: $0 [opções]"
  echo ""
  echo "Opções:"
  echo "  -p, --portainer-url URL      URL do Portainer (ex: https://painel.example.com)"
  echo "  -u, --portainer-user USER    Usuário do Portainer"
  echo "  -w, --portainer-password PWD Senha do Portainer"
  echo "  -d, --domain DOMAIN          Domínio principal (ex: example.com)"
  echo "  -h, --help                   Mostra esta ajuda"
  echo ""
  echo "Exemplo:"
  echo "  $0 -p https://painel.example.com -u admin -w senha123 -d example.com"
  exit 1
}

# Função para autenticar no Portainer
authenticate() {
  log "Autenticando no Portainer..." "$BLUE"
  
  local auth_data=$(cat <<EOF
{
  "Username": "$PORTAINER_USER",
  "Password": "$PORTAINER_PASSWORD"
}
EOF
)
  
  local response=$(curl -s -X POST \
    "${PORTAINER_URL}/api/auth" \
    -H "Content-Type: application/json" \
    -d "$auth_data")
  
  # Salvar resposta para debug
  mkdir -p "$TEMP_DIR"
  echo "$response" > "$TEMP_DIR/auth_response.json"
  
  # Verificar se houve erro
  if echo "$response" | grep -q "error" || ! echo "$response" | grep -q "jwt"; then
    local error_msg=$(echo "$response" | jq -r '.message // "Erro desconhecido"')
    log "Falha na autenticação: $error_msg" "$RED"
    exit 1
  fi
  
  # Extrair token JWT
  AUTH_TOKEN=$(echo "$response" | jq -r '.jwt')
  
  if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" == "null" ]; then
    log "Falha ao obter token JWT" "$RED"
    exit 1
  fi
  
  log "Autenticação bem-sucedida!" "$GREEN"
}

# Função para criar um stack usando a API
create_stack() {
  local stack_name="$1"
  local stack_content="$2"
  
  log "Criando stack '$stack_name'..." "$BLUE"
  
  # Salvar conteúdo do stack em um arquivo
  local stack_file="$TEMP_DIR/${stack_name}.yml"
  echo "$stack_content" > "$stack_file"
  
  # Criar o stack usando a API
  local response=$(curl -s -X POST \
    "${PORTAINER_URL}/api/stacks" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -F "Name=${stack_name}" \
    -F "SwarmID=default" \
    -F "file=@${stack_file}")
  
  # Salvar resposta para debug
  echo "$response" > "$TEMP_DIR/${stack_name}_response.json"
  
  # Verificar se houve erro
  if echo "$response" | grep -q "error" || echo "$response" | grep -q "message"; then
    local error_msg=$(echo "$response" | jq -r '.message // "Erro desconhecido"')
    log "Erro ao criar stack '$stack_name': $error_msg" "$RED"
    return 1
  fi
  
  log "Stack '$stack_name' criado com sucesso!" "$GREEN"
  return 0
}

# Função para gerar conteúdo dos stacks
generate_stack_contents() {
  # Remover prefixos http:// ou https:// do domínio
  local clean_domain=$(echo "$DOMAIN" | sed 's|^https://||' | sed 's|^http://||')
  
  # Redis stack
  cat > "$TEMP_DIR/redis.yml" << EOF
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
    name: redis_data

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOF

  # PostgreSQL stack
  cat > "$TEMP_DIR/postgres.yml" << EOF
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
    name: postgres_data

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOF

  # Evolution API stack
  cat > "$TEMP_DIR/evolution.yml" << EOF
version: "3.7"
services:
  evolution:
    image: atendai/evolution-api:latest
    volumes:
      - evolution_instances:/evolution/instances
    networks:
      - GrowthNet
    environment:
      # Configurações Gerais
      - SERVER_URL=https://api.${clean_domain}
      - AUTHENTICATION_API_KEY=2dc7b3194ce0704b12f68305f1904ca4
      - AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
      - DEL_INSTANCE=false
      - QRCODE_LIMIT=1902
      - LANGUAGE=pt-BR
      
      # Configuração do Cliente
      - CONFIG_SESSION_PHONE_VERSION=2.3000.1019780779
      - CONFIG_SESSION_PHONE_CLIENT=GrowthTap
      - CONFIG_SESSION_PHONE_NAME=Chrome
      
      # Configuração do Banco de Dados
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
      
      # Integrações
      - OPENAI_ENABLED=true
      - DIFY_ENABLED=true
      - TYPEBOT_ENABLED=true
      - TYPEBOT_API_VERSION=latest
      - CHATWOOT_ENABLED=true
      - CHATWOOT_MESSAGE_READ=true
      - CHATWOOT_MESSAGE_DELETE=true
      - CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/chatwoot?sslmode=disable
      - CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=false
      
      # Configuração do Cache
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
      - traefik.http.routers.evolution.rule=Host(\`api.${clean_domain}\`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.priority=1
      - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
      - traefik.http.routers.evolution.service=evolution
      - traefik.http.services.evolution.loadbalancer.server.port=8080
      - traefik.http.services.evolution.loadbalancer.passHostHeader=true

volumes:
  evolution_instances:
    external: true
    name: evolution_instances

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOF
}

# Função para criar volumes
create_volumes_manually() {
  log "Verificando e criando volumes necessários..." "$BLUE"
  
  docker volume create redis_data || log "Volume redis_data já existe" "$YELLOW"
  docker volume create postgres_data || log "Volume postgres_data já existe" "$YELLOW"
  docker volume create evolution_instances || log "Volume evolution_instances já existe" "$YELLOW"
}

# Função para criar rede
create_network_manually() {
  log "Verificando e criando rede GrowthNet..." "$BLUE"
  
  if ! docker network ls | grep -q "GrowthNet"; then
    docker network create --driver overlay GrowthNet
    log "Rede GrowthNet criada com sucesso!" "$GREEN"
  else
    log "Rede GrowthNet já existe." "$YELLOW"
  fi
}

# Função para salvar credenciais
save_credentials() {
  local clean_domain=$(echo "$DOMAIN" | sed 's|^https://||' | sed 's|^http://||')
  
  log "Salvando credenciais..." "$BLUE"
  
  # Criar diretório para credenciais
  mkdir -p /root/.credentials
  chmod 700 /root/.credentials
  
  # Credenciais do Redis
  cat > /root/.credentials/redis.txt << EOF
Redis Information
URL: redis://redis:6379
Network: GrowthNet
Volume: redis_data
EOF
  chmod 600 /root/.credentials/redis.txt
  
  # Credenciais do PostgreSQL
  cat > /root/.credentials/postgres.txt << EOF
PostgreSQL Information
Host: postgres
Port: 5432
User: postgres
Password: b2ecbaa44551df03fa3793b38091cff7
Network: GrowthNet
Volume: postgres_data
EOF
  chmod 600 /root/.credentials/postgres.txt
  
  # Credenciais da Evolution API
  cat > /root/.credentials/evolution.txt << EOF
Evolution API Information
URL: https://api.${clean_domain}
API Key: 2dc7b3194ce0704b12f68305f1904ca4
Network: GrowthNet
Volume: evolution_instances
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF
  chmod 600 /root/.credentials/evolution.txt
  
  # Credenciais do Portainer
  cat > /root/.credentials/portainer.txt << EOF
Portainer Admin Credentials
URL: ${PORTAINER_URL}
Username: ${PORTAINER_USER}
Password: ${PORTAINER_PASSWORD}
EOF
  chmod 600 /root/.credentials/portainer.txt
  
  log "Credenciais salvas em /root/.credentials/" "$GREEN"
}

# Função principal
main() {
  # Verificar se jq está instalado
  if ! command -v jq &> /dev/null; then
    log "Instalando jq..." "$YELLOW"
    apt update && apt install -y jq
  fi
  
  # Processar argumentos
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--portainer-url)
        PORTAINER_URL="$2"
        shift 2
        ;;
      -u|--portainer-user)
        PORTAINER_USER="$2"
        shift 2
        ;;
      -w|--portainer-password)
        PORTAINER_PASSWORD="$2"
        shift 2
        ;;
      -d|--domain)
        DOMAIN="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        log "Opção desconhecida: $1" "$RED"
        usage
        ;;
    esac
  done
  
  # Verificar argumentos obrigatórios
  if [ -z "$PORTAINER_URL" ] || [ -z "$PORTAINER_USER" ] || [ -z "$PORTAINER_PASSWORD" ] || [ -z "$DOMAIN" ]; then
    log "Todos os argumentos são obrigatórios!" "$RED"
    usage
  fi
  
  # Criar diretório temporário
  mkdir -p "$TEMP_DIR"
  
  # Autenticar no Portainer
  authenticate
  
  # Criar volumes manualmente (não através da API)
  create_volumes_manually
  
  # Criar rede manualmente (não através da API)
  create_network_manually
  
  # Gerar conteúdo dos stacks
  generate_stack_contents
  
  # Criar stacks
  create_stack "redis" "$(cat $TEMP_DIR/redis.yml)"
  create_stack "postgres" "$(cat $TEMP_DIR/postgres.yml)"
  create_stack "evolution" "$(cat $TEMP_DIR/evolution.yml)"
  
  # Salvar credenciais
  save_credentials
  
  log "Instalação concluída com sucesso!" "$GREEN"
  log "Acesse a Evolution API em: https://api.$(echo "$DOMAIN" | sed 's|^https://||' | sed 's|^http://||')" "$GREEN"
  log "Credenciais salvas em: /root/.credentials/" "$GREEN"
}

# Iniciar o script
main "$@"
