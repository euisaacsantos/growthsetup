#!/bin/bash
#
# Script de Instalação Direta - Redis, PostgreSQL e Evolution API
# Versão: 1.0
# Data: 26/03/2025
#
# Este script instala diretamente usando comandos Docker:
# - Redis
# - PostgreSQL
# - Evolution API

# Cores para melhor visualização
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
  echo "  -d, --domain DOMAIN         Domínio principal (ex: example.com)"
  echo "  -f, --force                 Forçar reinstalação mesmo se os serviços já existirem"
  echo "  -h, --help                  Mostrar esta ajuda"
  echo ""
  echo "Exemplo:"
  echo "  $0 --domain trafegocomia.com"
  exit 1
}

# Função para verificar se está sendo executado como root
check_root() {
  if [ "$(id -u)" != "0" ]; then
    log "Este script precisa ser executado como root!" "$RED"
    exit 1
  fi
}

# Função para instalar dependências
install_dependencies() {
  log "Verificando dependências..." "$BLUE"
  
  # Verificar se o Docker está instalado
  if ! command -v docker &> /dev/null; then
    log "Docker não encontrado. Instalando..." "$YELLOW"
    
    # Atualizar listas de pacotes
    apt update
    
    # Instalar pacotes necessários
    apt install -y apt-transport-https ca-certificates curl software-properties-common
    
    # Adicionar chave GPG oficial do Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Adicionar repositório do Docker
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Atualizar listas de pacotes e instalar Docker
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    
    log "Docker instalado com sucesso!" "$GREEN"
  else
    log "Docker já está instalado." "$GREEN"
  fi
  
  # Verificar se o Docker está em execução
  if ! systemctl is-active --quiet docker; then
    log "Iniciando serviço Docker..." "$YELLOW"
    systemctl start docker
  fi
  
  # Habilitar Docker na inicialização
  systemctl enable docker
}

# Função para verificar se o Docker Swarm está inicializado
check_swarm() {
  log "Verificando Docker Swarm..." "$BLUE"
  
  if ! docker info | grep -q "Swarm: active"; then
    log "Docker Swarm não está ativo. Inicializando..." "$YELLOW"
    
    # Obter o IP primário
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    
    # Inicializar o swarm
    docker swarm init --advertise-addr "$SERVER_IP"
    
    log "Docker Swarm inicializado com sucesso!" "$GREEN"
  else
    log "Docker Swarm já está ativo." "$GREEN"
  fi
}

# Função para criar rede
create_network() {
  log "Verificando rede GrowthNet..." "$BLUE"
  
  if ! docker network ls | grep -q "GrowthNet"; then
    log "Criando rede GrowthNet..." "$YELLOW"
    docker network create --driver overlay GrowthNet
    log "Rede GrowthNet criada com sucesso!" "$GREEN"
  else
    log "Rede GrowthNet já existe." "$GREEN"
  fi
}

# Função para criar volumes
create_volumes() {
  log "Verificando volumes necessários..." "$BLUE"
  
  # Verificar e criar volume para o Redis
  if ! docker volume ls | grep -q "redis_data"; then
    log "Criando volume redis_data..." "$YELLOW"
    docker volume create redis_data
    log "Volume redis_data criado com sucesso!" "$GREEN"
  else
    log "Volume redis_data já existe." "$GREEN"
  fi
  
  # Verificar e criar volume para o PostgreSQL
  if ! docker volume ls | grep -q "postgres_data"; then
    log "Criando volume postgres_data..." "$YELLOW"
    docker volume create postgres_data
    log "Volume postgres_data criado com sucesso!" "$GREEN"
  else
    log "Volume postgres_data já existe." "$GREEN"
  fi
  
  # Verificar e criar volume para a Evolution API
  if ! docker volume ls | grep -q "evolution_instances"; then
    log "Criando volume evolution_instances..." "$YELLOW"
    docker volume create evolution_instances
    log "Volume evolution_instances criado com sucesso!" "$GREEN"
  else
    log "Volume evolution_instances já existe." "$GREEN"
  fi
}

# Função para instalar o Redis
install_redis() {
  local force=$1
  
  log "Verificando serviço Redis..." "$BLUE"
  
  # Verificar se o serviço já existe
  if docker service ls | grep -q "redis"; then
    if [ "$force" = true ]; then
      log "Serviço Redis já existe. Removendo para reinstalação..." "$YELLOW"
      docker service rm redis
      sleep 5 # Aguardar remoção completa
    else
      log "Serviço Redis já existe. Pulando instalação." "$YELLOW"
      return 0
    fi
  fi
  
  log "Instalando Redis..." "$BLUE"
  
  # Criar serviço Redis
  docker service create \
    --name redis \
    --network GrowthNet \
    --mount type=volume,source=redis_data,target=/data \
    --constraint 'node.role == manager' \
    redis:latest redis-server --appendonly yes
  
  log "Redis instalado com sucesso!" "$GREEN"
}

# Função para instalar o PostgreSQL
install_postgres() {
  local force=$1
  
  log "Verificando serviço PostgreSQL..." "$BLUE"
  
  # Verificar se o serviço já existe
  if docker service ls | grep -q "postgres"; then
    if [ "$force" = true ]; then
      log "Serviço PostgreSQL já existe. Removendo para reinstalação..." "$YELLOW"
      docker service rm postgres
      sleep 5 # Aguardar remoção completa
    else
      log "Serviço PostgreSQL já existe. Pulando instalação." "$YELLOW"
      return 0
    fi
  fi
  
  log "Instalando PostgreSQL..." "$BLUE"
  
  # Criar serviço PostgreSQL
  docker service create \
    --name postgres \
    --network GrowthNet \
    --mount type=volume,source=postgres_data,target=/var/lib/postgresql/data \
    --env POSTGRES_PASSWORD=b2ecbaa44551df03fa3793b38091cff7 \
    --env POSTGRES_USER=postgres \
    --constraint 'node.role == manager' \
    postgres:13
  
  log "PostgreSQL instalado com sucesso!" "$GREEN"
}

# Função para instalar a Evolution API
install_evolution() {
  local domain=$1
  local force=$2
  
  log "Verificando serviço Evolution API..." "$BLUE"
  
  # Verificar se o serviço já existe
  if docker service ls | grep -q "evolution"; then
    if [ "$force" = true ]; then
      log "Serviço Evolution API já existe. Removendo para reinstalação..." "$YELLOW"
      docker service rm evolution
      sleep 5 # Aguardar remoção completa
    else
      log "Serviço Evolution API já existe. Pulando instalação." "$YELLOW"
      return 0
    fi
  fi
  
  log "Instalando Evolution API..." "$BLUE"
  
  # Remover qualquer prefixo http:// ou https:// do domínio
  local clean_domain=$(echo "$domain" | sed 's|^https://||' | sed 's|^http://||')
  
  # Criar serviço Evolution API
  docker service create \
    --name evolution \
    --network GrowthNet \
    --mount type=volume,source=evolution_instances,target=/evolution/instances \
    --env SERVER_URL=https://api.${clean_domain} \
    --env AUTHENTICATION_API_KEY=2dc7b3194ce0704b12f68305f1904ca4 \
    --env AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true \
    --env DEL_INSTANCE=false \
    --env QRCODE_LIMIT=1902 \
    --env LANGUAGE=pt-BR \
    --env CONFIG_SESSION_PHONE_VERSION=2.3000.1019780779 \
    --env CONFIG_SESSION_PHONE_CLIENT=GrowthTap \
    --env CONFIG_SESSION_PHONE_NAME=Chrome \
    --env DATABASE_ENABLED=true \
    --env DATABASE_PROVIDER=postgresql \
    --env DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution \
    --env DATABASE_CONNECTION_CLIENT_NAME=evolution \
    --env DATABASE_SAVE_DATA_INSTANCE=true \
    --env DATABASE_SAVE_DATA_NEW_MESSAGE=true \
    --env DATABASE_SAVE_MESSAGE_UPDATE=true \
    --env DATABASE_SAVE_DATA_CONTACTS=true \
    --env DATABASE_SAVE_DATA_CHATS=true \
    --env DATABASE_SAVE_DATA_LABELS=true \
    --env DATABASE_SAVE_DATA_HISTORIC=true \
    --env OPENAI_ENABLED=true \
    --env DIFY_ENABLED=true \
    --env TYPEBOT_ENABLED=true \
    --env TYPEBOT_API_VERSION=latest \
    --env CHATWOOT_ENABLED=true \
    --env CHATWOOT_MESSAGE_READ=true \
    --env CHATWOOT_MESSAGE_DELETE=true \
    --env CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/chatwoot?sslmode=disable \
    --env CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=false \
    --env CACHE_REDIS_ENABLED=true \
    --env CACHE_REDIS_URI=redis://redis:6379/8 \
    --env CACHE_REDIS_PREFIX_KEY=evolution \
    --env CACHE_REDIS_SAVE_INSTANCES=false \
    --env CACHE_LOCAL_ENABLED=false \
    --constraint 'node.role == manager' \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.evolution.rule=Host(\`api.${clean_domain}\`)" \
    --label "traefik.http.routers.evolution.entrypoints=websecure" \
    --label "traefik.http.routers.evolution.priority=1" \
    --label "traefik.http.routers.evolution.tls.certresolver=letsencryptresolver" \
    --label "traefik.http.routers.evolution.service=evolution" \
    --label "traefik.http.services.evolution.loadbalancer.server.port=8080" \
    --label "traefik.http.services.evolution.loadbalancer.passHostHeader=true" \
    atendai/evolution-api:latest
  
  log "Evolution API instalada com sucesso!" "$GREEN"
}

# Função para salvar credenciais
save_credentials() {
  local domain=$1
  
  log "Salvando credenciais..." "$BLUE"
  
  # Remover prefixos http:// ou https:// do domínio
  local clean_domain=$(echo "$domain" | sed 's|^https://||' | sed 's|^http://||')
  
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
  
  log "Credenciais salvas em /root/.credentials/" "$GREEN"
}

# Função para verificar status dos serviços
check_services() {
  log "Verificando status dos serviços..." "$BLUE"
  
  # Esperar um pouco para os serviços iniciarem
  sleep 5
  
  # Listar serviços
  docker service ls
  
  # Verificar Redis
  if docker service ls | grep -q "redis"; then
    log "Serviço Redis: ATIVO" "$GREEN"
  else
    log "Serviço Redis: NÃO ENCONTRADO" "$RED"
  fi
  
  # Verificar PostgreSQL
  if docker service ls | grep -q "postgres"; then
    log "Serviço PostgreSQL: ATIVO" "$GREEN"
  else
    log "Serviço PostgreSQL: NÃO ENCONTRADO" "$RED"
  fi
  
  # Verificar Evolution API
  if docker service ls | grep -q "evolution"; then
    log "Serviço Evolution API: ATIVO" "$GREEN"
  else
    log "Serviço Evolution API: NÃO ENCONTRADO" "$RED"
  fi
}

# Função principal
main() {
  local domain=""
  local force=false
  
  # Processar argumentos
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--domain)
        domain="$2"
        shift 2
        ;;
      -f|--force)
        force=true
        shift
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
  if [ -z "$domain" ]; then
    log "Argumento obrigatório faltando: domain" "$RED"
    usage
  fi
  
  # Verificar se está sendo executado como root
  check_root
  
  # Instalar dependências
  install_dependencies
  
  # Verificar e inicializar Docker Swarm
  check_swarm
  
  # Criar rede
  create_network
  
  # Criar volumes
  create_volumes
  
  # Instalar serviços
  install_redis "$force"
  install_postgres "$force"
  install_evolution "$domain" "$force"
  
  # Salvar credenciais
  save_credentials "$domain"
  
  # Verificar status dos serviços
  check_services
  
  log "Instalação concluída com sucesso!" "$GREEN"
  log "Acesse a Evolution API em: https://api.$(echo "$domain" | sed 's|^https://||' | sed 's|^http://||')" "$GREEN"
  log "Credenciais salvas em: /root/.credentials/" "$GREEN"
}

# Iniciar o script
main "$@"
