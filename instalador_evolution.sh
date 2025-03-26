#!/bin/bash
#
# Growth Installer - Script para instalação automatizada de sistemas
# Versão: 1.0
# Data: 26/03/2025
#
# Este script permite a instalação automatizada de sistemas como:
# - Redis
# - PostgreSQL
# - Evolution API
# - Outros sistemas (conforme configurado)
#
# O script verifica dependências, cria recursos necessários
# e instala os sistemas na ordem correta.

# Cores para exibição
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arquivo de log
LOG_FILE="/var/log/growth-installer.log"

# Diretório para arquivos temporários
TEMP_DIR="/tmp/growth-installer"

# Função para exibir mensagens de log
log() {
  local msg="$1"
  local color="${2:-$GREEN}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${color}[${timestamp}] $msg${NC}" | tee -a "$LOG_FILE"
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
  echo "  -s, --systems SYS1,SYS2,...  Sistemas a instalar (separados por vírgula)"
  echo "                               Sistemas disponíveis: redis,postgres,evolution"
  echo "  -h, --help                   Mostra esta ajuda"
  echo ""
  echo "Exemplo:"
  echo "  $0 -p https://painel.example.com -u admin -w senha123 -d example.com -s redis,postgres,evolution"
  exit 1
}

# Função para validar URL
validate_url() {
  local url=$1
  if [[ ! $url =~ ^https?:// ]]; then
    log "URL invalida: $url. Deve começar com http:// ou https://" "$RED"
    exit 1
  fi
}

# Função para verificar dependências
check_dependencies() {
  local missing_deps=()
  
  # Verificar curl
  if ! command -v curl &>/dev/null; then
    missing_deps+=("curl")
  fi
  
  # Verificar jq
  if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
  fi
  
  # Se houver dependências faltando, instale-as
  if [ ${#missing_deps[@]} -gt 0 ]; then
    log "Instalando dependências: ${missing_deps[*]}" "$YELLOW"
    apt update
    apt install -y "${missing_deps[@]}"
  fi
}

# Função para autenticar no Portainer e obter token JWT
authenticate_portainer() {
  local portainer_url="$1"
  local username="$2"
  local password="$3"
  
  log "Autenticando no Portainer..." "$BLUE"
  
  local auth_data=$(cat <<EOF
{
  "Username": "$username",
  "Password": "$password"
}
EOF
)
  
  local response=$(curl -s -X POST \
    "${portainer_url}/api/auth" \
    -H "Content-Type: application/json" \
    -d "$auth_data")
  
  # Verificar se houve erro
  if echo "$response" | grep -q "error"; then
    local error_msg=$(echo "$response" | jq -r '.message // "Erro desconhecido"')
    log "Falha na autenticação: $error_msg" "$RED"
    exit 1
  fi
  
  # Extrair token JWT
  local jwt=$(echo "$response" | jq -r '.jwt')
  
  if [ "$jwt" == "null" ] || [ -z "$jwt" ]; then
    log "Falha ao obter token JWT" "$RED"
    exit 1
  fi
  
  echo "$jwt"
}

# Função para verificar se um stack existe
check_stack_exists() {
  local stack_name="$1"
  local portainer_url="$2"
  local auth_token="$3"
  
  log "Verificando se o stack '$stack_name' existe..." "$BLUE"
  
  local response=$(curl -s -X GET \
    "${portainer_url}/api/stacks" \
    -H "Authorization: Bearer ${auth_token}")
  
  echo "$response" | jq -e '.[] | select(.Name == "'"$stack_name"'")' &>/dev/null
  return $?
}

# Função para verificar se uma rede existe
check_network_exists() {
  local network_name="$1"
  local portainer_url="$2"
  local auth_token="$3"
  
  log "Verificando se a rede '$network_name' existe..." "$BLUE"
  
  local response=$(curl -s -X GET \
    "${portainer_url}/api/endpoints/1/docker/networks" \
    -H "Authorization: Bearer ${auth_token}")
  
  echo "$response" | jq -e '.[] | select(.Name == "'"$network_name"'")' &>/dev/null
  return $?
}

# Função para verificar se um volume existe
check_volume_exists() {
  local volume_name="$1"
  local portainer_url="$2"
  local auth_token="$3"
  
  log "Verificando se o volume '$volume_name' existe..." "$BLUE"
  
  local response=$(curl -s -X GET \
    "${portainer_url}/api/endpoints/1/docker/volumes" \
    -H "Authorization: Bearer ${auth_token}")
  
  echo "$response" | jq -e '.Volumes[] | select(.Name == "'"$volume_name"'")' &>/dev/null
  return $?
}

# Função para criar uma rede
create_network() {
  local network_name="$1"
  local portainer_url="$2"
  local auth_token="$3"
  
  log "Criando rede '$network_name'..." "$BLUE"
  
  local network_data=$(cat <<EOF
{
  "Name": "$network_name",
  "Driver": "overlay",
  "CheckDuplicate": true
}
EOF
)
  
  local response=$(curl -s -X POST \
    "${portainer_url}/api/endpoints/1/docker/networks/create" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d "$network_data")
  
  # Verificar se houve erro
  if echo "$response" | grep -q "error" || echo "$response" | grep -q "message"; then
    local error_msg=$(echo "$response" | jq -r '.message // "Erro desconhecido"')
    log "Erro ao criar rede: $error_msg" "$RED"
    return 1
  fi
  
  log "Rede '$network_name' criada com sucesso!" "$GREEN"
  return 0
}

# Função para criar um volume
create_volume() {
  local volume_name="$1"
  local portainer_url="$2"
  local auth_token="$3"
  
  log "Criando volume '$volume_name'..." "$BLUE"
  
  local volume_data=$(cat <<EOF
{
  "Name": "$volume_name"
}
EOF
)
  
  local response=$(curl -s -X POST \
    "${portainer_url}/api/endpoints/1/docker/volumes/create" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d "$volume_data")
  
  # Verificar se houve erro
  if echo "$response" | grep -q "error" || echo "$response" | grep -q "message"; then
    local error_msg=$(echo "$response" | jq -r '.message // "Erro desconhecido"')
    log "Erro ao criar volume: $error_msg" "$RED"
    return 1
  fi
  
  log "Volume '$volume_name' criado com sucesso!" "$GREEN"
  return 0
}

# Função para criar um stack
create_stack() {
  local stack_name="$1"
  local stack_content="$2"
  local portainer_url="$3"
  local auth_token="$4"
  
  log "Criando stack '$stack_name'..." "$BLUE"
  
  # Salvar conteúdo do stack em um arquivo temporário para depuração
  mkdir -p "$TEMP_DIR"
  echo "$stack_content" > "${TEMP_DIR}/${stack_name}.yml"
  
  # Preparar dados para a API
  local stack_data=$(cat <<EOF
{
  "Name": "$stack_name",
  "StackFileContent": $(echo "$stack_content" | jq -Rs .),
  "SwarmID": "default"
}
EOF
)
  
  local response=$(curl -s -X POST \
    "${portainer_url}/api/stacks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${auth_token}" \
    -d "$stack_data")
  
  # Verificar se houve erro
  if echo "$response" | grep -q "error" || echo "$response" | grep -q "message"; then
    local error_msg=$(echo "$response" | jq -r '.message // "Erro desconhecido"')
    log "Erro ao criar stack '$stack_name': $error_msg" "$RED"
    return 1
  fi
  
  log "Stack '$stack_name' criado com sucesso!" "$GREEN"
  return 0
}

# Função para aguardar um serviço ficar pronto
wait_for_service() {
  local service_name="$1"
  local portainer_url="$2"
  local auth_token="$3"
  local max_attempts="$4"
  
  log "Aguardando serviço '$service_name' ficar pronto..." "$BLUE"
  
  for (( attempt=1; attempt<=$max_attempts; attempt++ )); do
    local response=$(curl -s -X GET \
      "${portainer_url}/api/endpoints/1/docker/services" \
      -H "Authorization: Bearer ${auth_token}")
    
    # Verificar se o serviço existe e está rodando
    if echo "$response" | jq -e '.[] | select(.Spec.Name | contains("'"$service_name"'"))' &>/dev/null; then
      local service=$(echo "$response" | jq -r '.[] | select(.Spec.Name | contains("'"$service_name"'"))')
      local replicas=$(echo "$service" | jq -r '.Spec.Mode.Replicated.Replicas')
      local running=$(echo "$service" | jq -r '.ServiceStatus.RunningTasks')
      
      if [ "$replicas" == "$running" ]; then
        log "Serviço '$service_name' está pronto! ($running/$replicas réplicas rodando)" "$GREEN"
        return 0
      fi
      
      log "Serviço '$service_name' iniciando... ($running/$replicas réplicas rodando) - Tentativa $attempt/$max_attempts" "$YELLOW"
    else
      log "Serviço '$service_name' não encontrado - Tentativa $attempt/$max_attempts" "$YELLOW"
    fi
    
    # Aguardar antes da próxima verificação
    sleep 5
  done
  
  log "Tempo limite excedido aguardando '$service_name'" "$RED"
  return 1
}

# Função para gerar arquivo de configuração do Redis
generate_redis_config() {
  local domain="$1"
  
  cat <<EOF
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
# Função para salvar credenciais
save_credentials() {
  local systems="$1"
  local domain="$2"
  local portainer_url="$3"
  local portainer_user="$4"
  local portainer_password="$5"
  
  # Criar diretório para credenciais
  mkdir -p /root/.credentials
  chmod 700 /root/.credentials
  
  # Arquivo para credenciais do Portainer
  cat > /root/.credentials/portainer.txt << EOF
Portainer Admin Credentials
URL: ${portainer_url}
Username: ${portainer_user}
Password: ${portainer_password}
EOF
  chmod 600 /root/.credentials/portainer.txt
  
  # Arquivo para cada sistema instalado
  for system in ${systems//,/ }; do
    case "$system" in
      "redis")
        cat > /root/.credentials/redis.txt << EOF
Redis Information
URL: redis://redis:6379
Network: GrowthNet
Volume: redis_data
EOF
        ;;
      "postgres")
        cat > /root/.credentials/postgres.txt << EOF
PostgreSQL Information
Host: postgres
Port: 5432
User: postgres
Password: b2ecbaa44551df03fa3793b38091cff7
Network: GrowthNet
Volume: postgres_data
EOF
        ;;
      "evolution")
        cat > /root/.credentials/evolution.txt << EOF
Evolution API Information
URL: https://api.${domain}
API Key: 2dc7b3194ce0704b12f68305f1904ca4
Network: GrowthNet
Volume: evolution_instances
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF
        ;;
    esac
    chmod 600 /root/.credentials/${system}.txt
  done
  
  log "Credenciais salvas em /root/.credentials/" "$GREEN"
}

# Função para instalar sistemas
install_systems() {
  local systems="$1"
  local domain="$2"
  local portainer_url="$3"
  local portainer_user="$4"
  local portainer_password="$5"
  
  # Criar diretório temporário
  mkdir -p "$TEMP_DIR"
  
  # Obter token de autenticação
  local auth_token=$(authenticate_portainer "$portainer_url" "$portainer_user" "$portainer_password")
  
  # Verificar e criar rede GrowthNet se necessário
  if ! check_network_exists "GrowthNet" "$portainer_url" "$auth_token"; then
    create_network "GrowthNet" "$portainer_url" "$auth_token" || {
      log "Falha ao criar rede GrowthNet. Abortando." "$RED"
      exit 1
    }
  else
    log "Rede GrowthNet já existe." "$GREEN"
  fi
  
  # Definir a ordem de instalação e dependências
  local install_order=""
  local redis_needed=false
  local postgres_needed=false
  
  for system in ${systems//,/ }; do
    case "$system" in
      "evolution")
        redis_needed=true
        postgres_needed=true
        ;;
    esac
  done
  
  # Montar a ordem de instalação baseada nas dependências
  if [ "$redis_needed" = true ] && [[ "$systems" != *"redis"* ]]; then
    install_order="redis "
  fi
  
  if [ "$postgres_needed" = true ] && [[ "$systems" != *"postgres"* ]]; then
    install_order="${install_order}postgres "
  fi
  
  # Adicionar os sistemas solicitados na ordem correta
  for system in redis postgres evolution; do
    if [[ "$systems" == *"$system"* ]]; then
      install_order="${install_order}${system} "
    fi
  done
  
  log "Ordem de instalação: ${install_order}" "$BLUE"
  
  # Instalar cada sistema na ordem determinada
  for system in $install_order; do
    # Verificar se o sistema já está instalado
    if check_stack_exists "$system" "$portainer_url" "$auth_token"; then
      log "Sistema '$system' já está instalado. Pulando." "$YELLOW"
      continue
    fi
    
    # Verificar e criar volumes necessários
    case "$system" in
      "redis")
        if ! check_volume_exists "redis_data" "$portainer_url" "$auth_token"; then
          create_volume "redis_data" "$portainer_url" "$auth_token"
        fi
        ;;
      "postgres")
        if ! check_volume_exists "postgres_data" "$portainer_url" "$auth_token"; then
          create_volume "postgres_data" "$portainer_url" "$auth_token"
        fi
        ;;
      "evolution")
        if ! check_volume_exists "evolution_instances" "$portainer_url" "$auth_token"; then
          create_volume "evolution_instances" "$portainer_url" "$auth_token"
        fi
        ;;
    esac
    
    # Gerar configuração do sistema
    local config=""
    case "$system" in
      "redis")
        config=$(generate_redis_config "$domain")
        ;;
      "postgres")
        config=$(generate_postgres_config "$domain")
        ;;
      "evolution")
        config=$(generate_evolution_config "$domain")
        ;;
      *)
        log "Sistema desconhecido: $system. Pulando." "$RED"
        continue
        ;;
    esac
    
    # Criar o stack
    if create_stack "$system" "$config" "$portainer_url" "$auth_token"; then
      log "Aguardando inicialização do serviço '$system'..." "$BLUE"
      if ! wait_for_service "$system" "$portainer_url" "$auth_token" 12; then
        log "Aviso: Tempo limite excedido aguardando '$system'. Continuando mesmo assim." "$YELLOW"
      fi
    else
      log "Falha ao criar stack para '$system'. Continuando com outros sistemas." "$RED"
    fi
  done
  
  # Salvar credenciais
  save_credentials "$systems" "$domain" "$portainer_url" "$portainer_user" "$portainer_password"
  
  log "Instalação concluída!" "$GREEN"
}

# Função principal
main() {
  # Inicializar variáveis
  local portainer_url=""
  local portainer_user=""
  local portainer_password=""
  local domain=""
  local systems=""
  
  # Processar argumentos
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--portainer-url)
        portainer_url="$2"
        shift 2
        ;;
      -u|--portainer-user)
        portainer_user="$2"
        shift 2
        ;;
      -w|--portainer-password)
        portainer_password="$2"
        shift 2
        ;;
      -d|--domain)
        domain="$2"
        shift 2
        ;;
      -s|--systems)
        systems="$2"
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
  
  # Validar argumentos obrigatórios
  if [ -z "$portainer_url" ] || [ -z "$portainer_user" ] || [ -z "$portainer_password" ] || [ -z "$domain" ] || [ -z "$systems" ]; then
    log "Argumentos obrigatórios faltando!" "$RED"
    usage
  fi
  
  # Validar URL do Portainer
  validate_url "$portainer_url"
  
  # Verificar dependências
  check_dependencies
  
  # Iniciar instalação
  install_systems "$systems" "$domain" "$portainer_url" "$portainer_user" "$portainer_password"
}

# Iniciar o script
main "$@"
