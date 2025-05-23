#!/bin/bash
# Script para configuração de Docker Swarm, Portainer e Traefik
# Versão: 7.3 - Com suporte a ID de instalação, logs completos e correção automática de problemas GRUB
# Data: 23/05/2025

# Cores para melhor visualização
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variáveis globais
MAX_RETRIES=3
RETRY_COUNT=0
SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/swarm-setup.log"
NETWORK_NAME="GrowthNet"
WEBHOOK_URL="https://setup.growthtap.com.br/webhook/bf813e80-f036-400b-acae-904d703df6dd"

# Variáveis para sistema de logs
INSTALL_LOG=""
ERROR_LOG=""
INSTALL_STATUS="success"

# Função para adicionar ao log
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] $message"
    echo "$log_entry"
    INSTALL_LOG+="$log_entry\n"
    # Também adicionar ao arquivo de log existente
    echo "$log_entry" >> "$LOG_FILE"
}

# Função para adicionar ao log de erro
log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local error_entry="[$timestamp] ERROR: $message"
    echo -e "\e[31m$error_entry\e[0m" >&2
    ERROR_LOG+="$error_entry\n"
    INSTALL_STATUS="error"
    # Também adicionar ao arquivo de log existente
    echo "$error_entry" >> "$LOG_FILE"
}

# Função para enviar webhook com logs
send_webhook_with_logs() {
    local final_status="$1"
    local final_message="$2"
    
    # Escapar caracteres especiais para JSON
    local escaped_install_log=$(echo -e "$INSTALL_LOG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n')
    local escaped_error_log=$(echo -e "$ERROR_LOG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n')
    
    # Coletar informações do servidor
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local hostname=$(hostname)
    local server_ip=$(hostname -I | awk '{print $1}')
    local os_info=$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d '"' -f 2)
    local kernel_version=$(uname -r)
    local cpu_info=$(grep "model name" /proc/cpuinfo | head -1 | cut -d ':' -f 2 | xargs)
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local disk_size=$(df -h / | awk 'NR==2 {print $2}')
    local disk_used=$(df -h / | awk 'NR==2 {print $3}')
    
    # Preparar os dados para enviar ao webhook com logs
    local webhook_data=$(cat << EOF
{
  "installation_id": "${INSTALLATION_ID}",
  "timestamp": "${timestamp}",
  "hostname": "${hostname}",
  "server_ip": "${server_ip}",
  "status": "${final_status}",
  "message": "${final_message}",
  "install_log": "${escaped_install_log}",
  "error_log": "${escaped_error_log}",
  "link": "https://${PORTAINER_DOMAIN}",
  "password": "${ADMIN_PASSWORD}",
  "system_info": {
    "os": "${os_info}",
    "kernel": "${kernel_version}",
    "cpu": "${cpu_info}",
    "memory_mb": ${mem_total},
    "disk_size": "${disk_size}",
    "disk_used": "${disk_used}"
  },
  "portainer": {
    "url": "https://${PORTAINER_DOMAIN}",
    "username": "admin",
    "password": "${ADMIN_PASSWORD}",
    "version": "2.19.0"
  },
  "traefik": {
    "version": "v2.11.2",
    "domain": "${DOMAIN}",
    "email": "${EMAIL}"
  },
  "network_name": "${NETWORK_NAME}"
}
EOF
)
    
    # Enviar para o webhook
    log_message "Enviando dados da instalação para o webhook..."
    local response=$(curl -s -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$webhook_data" \
      -w "\n%{http_code}")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ] || [ "$http_code" -eq 202 ]; then
        log_message "Dados enviados para o webhook com sucesso!"
    else
        log_error "Erro ao enviar dados para o webhook. Código: $http_code. Resposta: $body"
    fi
}

# Função para exibir mensagens (mantendo compatibilidade com versão anterior)
log() {
  local msg="$1"
  local color="${2:-$GREEN}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${color}[${timestamp}] $msg${NC}" | tee -a "$LOG_FILE"
  # Também adicionar ao sistema de logs
  INSTALL_LOG+="[$timestamp] $msg\n"
}

# Função para tratamento de erros
handle_error() {
  local error_msg="$1"
  local step="$2"
  local exit_code="${3:-1}"
  
  log_error "ERRO durante $step: $error_msg"
  log_error "Verifique o log em $LOG_FILE para mais detalhes."
  
  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_message "Tentando novamente ($RETRY_COUNT/$MAX_RETRIES)..."
    sleep 5
    main
  else
    log_error "Número máximo de tentativas atingido."
    log_error "Instalação abortada."
    send_webhook_with_logs "error" "Instalação abortada após $MAX_RETRIES tentativas: $error_msg"
    exit $exit_code
  fi
}

# Função para corrigir problemas com o pacote grub-efi-amd64-signed
fix_grub_efi_issues() {
  log_message "Detectado problema com o pacote grub-efi-amd64-signed..."
  log_message "Tentando corrigir automaticamente..."
  
  # Tentativa 1: Configurar pacotes pendentes
  log_message "Tentando configurar pacotes pendentes..."
  dpkg --configure -a
  
  # Tentativa 2: Corrigir dependências quebradas
  log_message "Tentando corrigir dependências quebradas..."
  apt-get -f install -y
  
  # Tentativa 3: Marcar o pacote problemático como "hold" para impedir atualizações
  log_message "Marcando pacote grub-efi-amd64-signed para não ser atualizado..."
  apt-mark hold grub-efi-amd64-signed
  
  # Verificar se o problema foi resolvido
  if apt update; then
    log_message "Problema corrigido com sucesso!"
    return 0
  else
    # Tentativa 4: Abordagem mais agressiva - remover e reinstalar o pacote
    log_message "Tentando abordagem alternativa..."
    apt-get remove -y --purge grub-efi-amd64-signed || true
    apt-get autoremove -y || true
    apt-get update
    apt-get install -y grub-efi-amd64-signed || apt-mark hold grub-efi-amd64-signed
    
    # Verificação final
    if apt update; then
      log_message "Problema corrigido com sucesso!"
      return 0
    else
      log_error "Não foi possível resolver o problema com grub-efi-amd64-signed"
      log_message "Continuando a instalação mesmo assim..."
      # Marcamos o pacote como hold para evitar que ele interfira no restante da instalação
      apt-mark hold grub-efi-amd64-signed
      return 1
    fi
  fi
}

# Iniciar o log da instalação
log_message "Iniciando configuração do ambiente Docker Swarm, Portainer e Traefik..."

# Verificar se está sendo executado como root
if [ "$EUID" -ne 0 ]; then
  log_error "Este script precisa ser executado como root."
  exit 1
fi

# Criar arquivo de log
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
log_message "Log iniciado em $LOG_FILE"

# Verificar argumentos
if [ "$#" -lt 1 ]; then
  log_error "Parâmetros insuficientes. Uso: $0 <subdominio-portainer> [dominio-principal] [email] [id-xxxx]"
  log_message "Exemplo: $0 portainer exemplo.com admin@exemplo.com id-12341221125"
  exit 1
fi

PORTAINER_SUBDOMAIN="$1"
DOMAIN="${2:-localhost}"
EMAIL="${3:-admin@$DOMAIN}"
INSTALLATION_ID="sem_id"

# Verificar se há ID de instalação nos argumentos
for param in "$@"; do
  # Verificar se o parâmetro começa com 'id-'
  if [[ "$param" == id-* ]]; then
    INSTALLATION_ID="${param#id-}"  # Remover o prefixo 'id-'
    log_message "ID da instalação: $INSTALLATION_ID"
    break
  fi
done

PORTAINER_DOMAIN="${PORTAINER_SUBDOMAIN}.${DOMAIN}"

log_message "Configurando com Portainer em: ${PORTAINER_DOMAIN}"
log_message "Email para certificados SSL: ${EMAIL}"

# Atualizar o sistema
update_system() {
  log_message "Atualizando o sistema..."
  
  export DEBIAN_FRONTEND=noninteractive
  
  # Tentar fazer o update primeiro
  if ! apt update; then
    log_message "Detectado erro durante o apt update, verificando problemas com grub-efi..."
    
    # Verificar se o erro está relacionado ao grub-efi-amd64-signed
    if apt update 2>&1 | grep -q "grub-efi-amd64-signed"; then
      fix_grub_efi_issues
    fi
  fi
  
  # Continuar com a atualização, independentemente do resultado anterior
  if apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y; then
    log_message "Sistema atualizado com sucesso!"
  else
    log_error "Erro durante a atualização do sistema, mas continuando..."
  fi
  
  # Verificar se há erros específicos após o upgrade
  if dpkg -l | grep -q "^..F" && dpkg -l | grep -q "grub-efi-amd64-signed"; then
    log_message "Detectados problemas com pacotes após upgrade, tentando correção..."
    fix_grub_efi_issues
  fi
  
  # Instalar pacotes necessários, mesmo se houver erros
  if apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y \
    curl wget apt-transport-https ca-certificates \
    software-properties-common gnupg jq host; then
    log_message "Pacotes necessários instalados com sucesso!"
  else
    log_error "Alguns pacotes podem não ter sido instalados corretamente."
    log_message "Continuando mesmo assim..."
  fi
}

# Instalar Docker
install_docker() {
  log_message "Instalando Docker..."
  
  apt remove -y docker docker-engine docker.io containerd runc || true
  
  # Adicionar a chave GPG oficial do Docker (com tratamento para evitar prompts)
  if [ -f "/usr/share/keyrings/docker-archive-keyring.gpg" ]; then
    log_message "Arquivo de chave GPG do Docker já existe, removendo para atualizar..."
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
  fi
  
  # Usar redirecionamento para evitar prompts
  if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
    log_message "Chave GPG do Docker adicionada com sucesso!"
  else
    log_error "Falha ao adicionar chave GPG do Docker"
    return 1
  fi
  
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt update
  if apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
    log_message "Docker instalado com sucesso!"
  else
    handle_error "Falha ao instalar o Docker" "instalação do Docker"
    return 1
  fi
  
  systemctl enable --now docker
  
  if ! docker --version; then
    log_error "Docker não foi instalado corretamente"
    return 1
  fi
  
  log_message "Docker instalado e configurado com sucesso!"
}

# Inicializar Docker Swarm
init_swarm() {
  log_message "Inicializando o Docker Swarm..."
  
  if docker info | grep -q "Swarm: active"; then
    log_message "Docker Swarm já está ativo neste nó."
  else
    SERVER_IP=$(hostname -I | awk '{print $1}')
    log_message "Inicializando Swarm com IP: $SERVER_IP"
    
    if docker swarm init --advertise-addr "$SERVER_IP"; then
      log_message "Docker Swarm inicializado com sucesso!"
    else
      handle_error "Falha ao inicializar o Docker Swarm" "inicialização do Swarm"
      return 1
    fi
  fi
  
  # Criar rede para os serviços
  if ! docker network ls | grep -q "$NETWORK_NAME"; then
    if docker network create --driver=overlay --attachable "$NETWORK_NAME"; then
      log_message "Rede '$NETWORK_NAME' criada com sucesso!"
    else
      handle_error "Falha ao criar rede $NETWORK_NAME" "criação de rede"
      return 1
    fi
  else
    log_message "Rede '$NETWORK_NAME' já existe."
  fi
  
  # Criar volumes necessários
  log_message "Criando volumes necessários..."
  
  if ! docker volume ls | grep -q "volume_swarm_shared"; then
    if docker volume create --name volume_swarm_shared; then
      log_message "Volume 'volume_swarm_shared' criado com sucesso!"
    else
      handle_error "Falha ao criar volume volume_swarm_shared" "criação de volume"
      return 1
    fi
  else
    log_message "Volume 'volume_swarm_shared' já existe."
  fi
  
  if ! docker volume ls | grep -q "volume_swarm_certificates"; then
    if docker volume create --name volume_swarm_certificates; then
      log_message "Volume 'volume_swarm_certificates' criado com sucesso!"
    else
      handle_error "Falha ao criar volume volume_swarm_certificates" "criação de volume"
      return 1
    fi
  else
    log_message "Volume 'volume_swarm_certificates' já existe."
  fi
  
  # Remover e recriar volume do Portainer para garantir configuração limpa
  docker volume rm -f portainer_data >/dev/null 2>&1 || true
  if docker volume create --name portainer_data; then
    log_message "Volume 'portainer_data' criado com sucesso!"
  else
    handle_error "Falha ao criar volume portainer_data" "criação de volume"
    return 1
  fi
}

# Verificar configuração de DNS
check_dns() {
  log_message "Verificando configuração DNS para ${PORTAINER_DOMAIN}..."
  
  local dns_check=$(host ${PORTAINER_DOMAIN} 2>&1 || true)
  log_message "Resultado da verificação DNS: ${dns_check}"
  
  if echo "$dns_check" | grep -q "NXDOMAIN" || echo "$dns_check" | grep -q "not found"; then
    log_error "Não foi possível resolver ${PORTAINER_DOMAIN}."
    log_message "Certifique-se de que o DNS está configurado corretamente apontando para o IP deste servidor."
    log_message "Os certificados SSL não funcionarão até que o DNS esteja corretamente configurado."
    
    local server_ip=$(hostname -I | awk '{print $1}')
    log_message "IP deste servidor: ${server_ip}"
    log_message "Configure seu DNS para que ${PORTAINER_DOMAIN} aponte para ${server_ip}"
    
    # Auto-responder 's' para permitir automatização
    log_message "Continuando mesmo assim para permitir automatização completa..."
  else
    log_message "DNS para ${PORTAINER_DOMAIN} está configurado corretamente!"
  fi
}

# Instalar e configurar Traefik usando docker-compose e stack
install_traefik() {
  log_message "Instalando Traefik usando Docker Stack..."
  
  # Remover instalação anterior se existir
  docker stack rm traefik || true
  
  # Esperar para serviço ser removido
  sleep 10
  
  # Criar diretório de log para Traefik
  mkdir -p /var/log/traefik
  chmod 755 /var/log/traefik
  log_message "Diretório de logs do Traefik criado."
  
  # Criar diretório para stack file
  mkdir -p /opt/stacks/traefik
  
  # Criar compose file para o Traefik
  cat > /opt/stacks/traefik/docker-compose.yml << EOF
version: "3.7"
services:
  traefik:
    image: traefik:v2.11.2
    command:
      - "--api.dashboard=true"
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.endpoint=unix:///var/run/docker.sock"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=${NETWORK_NAME}"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.transport.respondingTimeouts.idleTimeout=3600"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencryptresolver.acme.storage=/etc/traefik/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencryptresolver.acme.email=${EMAIL}"
      - "--log.level=DEBUG"
      - "--log.format=common"
      - "--log.filePath=/var/log/traefik/traefik.log"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access-log"

    volumes:
      - "vol_certificates:/etc/traefik/letsencrypt"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "/var/log/traefik:/var/log/traefik"

    networks:
      - ${NETWORK_NAME}

    ports:
      - target: 80
        published: 80
        mode: host
      - target: 443
        published: 443
        mode: host

    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.middlewares.redirect-https.redirectscheme.scheme=https"
        - "traefik.http.middlewares.redirect-https.redirectscheme.permanent=true"
        - "traefik.http.routers.http-catchall.rule=Host(\`{host:.+}\`)"
        - "traefik.http.routers.http-catchall.entrypoints=web"
        - "traefik.http.routers.http-catchall.middlewares=redirect-https@docker"
        - "traefik.http.routers.http-catchall.priority=1"

volumes:
  vol_shared:
    external: true
    name: volume_swarm_shared
  vol_certificates:
    external: true
    name: volume_swarm_certificates

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF
  
  # Implantar o stack do Traefik
  if docker stack deploy -c /opt/stacks/traefik/docker-compose.yml traefik; then
    log_message "Stack do Traefik implantado com sucesso!"
  else
    handle_error "Falha ao criar stack do Traefik" "implantação do Traefik"
    return 1
  fi
}

# Gerar senha sugerida para o Portainer
generate_suggested_password() {
  log_message "Gerando senha sugerida para o Portainer..."
  
  # Gerar uma senha aleatória com pelo menos 12 caracteres (letras e números apenas para evitar problemas)
  ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 12)
  
  # Garantir que a senha tenha pelo menos 12 caracteres
  while [ ${#ADMIN_PASSWORD} -lt 12 ]; do
    # Se por algum motivo a senha gerada for menor que 12 caracteres, gerar uma nova
    ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 12)
  done
  
  # Criar diretório para credenciais
  mkdir -p /root/.credentials
  chmod 700 /root/.credentials
  
  # Salvar a senha sugerida em um arquivo
  echo "${ADMIN_PASSWORD}" > /root/.credentials/portainer_password.txt
  chmod 600 /root/.credentials/portainer_password.txt
  
  # Salvar credenciais completas
  cat > /root/.credentials/portainer.txt << EOF
Portainer Admin Credentials
URL: https://${PORTAINER_DOMAIN}
Username: admin
Password sugerida: ${ADMIN_PASSWORD}
IMPORTANTE: Use esta senha no primeiro acesso ao definir a conta admin.
EOF
  chmod 600 /root/.credentials/portainer.txt
  
  log_message "Senha sugerida para o Portainer: ${ADMIN_PASSWORD}"
  log_message "Credenciais salvas em /root/.credentials/portainer.txt"
}

# Instalar e configurar Portainer usando docker-compose e stack
install_portainer() {
  log_message "Instalando Portainer com domínio: ${PORTAINER_DOMAIN}..."
  
  # Gerar senha sugerida
  generate_suggested_password
  
  # Remover instalação anterior se existir
  docker stack rm portainer || true
  
  # Esperar serviço ser removido
  sleep 10
  
  # Criar diretório para stack file
  mkdir -p /opt/stacks/portainer
  
  # Criar compose file para o Portainer (sem definir senha para garantir que funcione)
  cat > /opt/stacks/portainer/docker-compose.yml << EOF
version: "3.7"
services:
  portainer:
    image: portainer/portainer-ce:2.19.0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - ${NETWORK_NAME}
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"
        - "traefik.http.routers.portainer.tls.certresolver=letsencryptresolver"
        - "traefik.http.routers.portainer.service=portainer"
        - "traefik.docker.network=${NETWORK_NAME}"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.priority=1"
        - "traefik.http.services.portainer.loadbalancer.passHostHeader=1"

volumes:
  portainer_data:
    external: true
    name: portainer_data

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF
  
  # Implantar o stack do Portainer
  if docker stack deploy -c /opt/stacks/portainer/docker-compose.yml portainer; then
    log_message "Stack do Portainer implantado com sucesso!"
    log_message "URL do Portainer: https://${PORTAINER_DOMAIN}"
    log_message "IMPORTANTE: No primeiro acesso, você precisará definir uma senha para o admin"
    log_message "Senha sugerida (salva em /root/.credentials/portainer.txt): $(cat /root/.credentials/portainer_password.txt)"
  else
    handle_error "Falha ao criar stack do Portainer" "implantação do Portainer"
    return 1
  fi
}

# Verificar saúde dos serviços
check_services() {
  log_message "Verificando saúde dos serviços..."
  
  # Verificar se os stacks estão em execução
  if ! docker stack ls | grep -q "traefik"; then
    log_error "Stack Traefik não está em execução!"
    return 1
  fi
  
  if ! docker stack ls | grep -q "portainer"; then
    log_error "Stack Portainer não está em execução!"
    return 1
  fi
  
  # Verificar status de execução dos serviços
  local traefik_replicas=$(docker service ls --filter "name=traefik_traefik" --format "{{.Replicas}}")
  local portainer_replicas=$(docker service ls --filter "name=portainer_portainer" --format "{{.Replicas}}")
  
  if [[ "$traefik_replicas" != *"1/1"* ]]; then
    log_error "Serviço Traefik não está saudável: $traefik_replicas"
    return 1
  fi
  
  if [[ "$portainer_replicas" != *"1/1"* ]]; then
    log_error "Serviço Portainer não está saudável: $portainer_replicas"
    return 1
  fi
  
  log_message "Todos os serviços estão saudáveis!"
  return 0
}

# Função para fazer diagnóstico e correção automática
troubleshoot_services() {
  log_message "Iniciando diagnóstico de serviços..."
  
  # Verificar sistema
  log_message "Verificando recursos do sistema..."
  local total_mem=$(free -m | awk '/^Mem:/{print $2}')
  local used_mem=$(free -m | awk '/^Mem:/{print $3}')
  local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
  
  if [ "$total_mem" -lt 2000 ]; then
    log_error "Memória total ($total_mem MB) pode ser insuficiente para o Docker Swarm"
  fi
  
  if [ "$disk_usage" -gt 85 ]; then
    log_error "Uso de disco ($disk_usage%) está alto"
  fi
  
  # Verificar Docker
  log_message "Verificando status do Docker..."
  if ! systemctl is-active --quiet docker; then
    log_error "Docker não está rodando. Tentando reiniciar..."
    systemctl restart docker
    sleep 5
  fi
  
  # Limpar recursos não usados
  log_message "Limpando recursos Docker não utilizados..."
  docker system prune -f
  
  # Verificar logs do Traefik
  log_message "Verificando logs do Traefik..."
  docker service logs --tail 20 traefik_traefik 2>&1 | grep -i "error" || true
  
  # Verificar logs do Portainer
  log_message "Verificando logs do Portainer..."
  docker service logs --tail 20 portainer_portainer 2>&1 | grep -i "error" || true
  
  # Verificar configurações de rede
  log_message "Verificando configurações de rede..."
  if ! docker network inspect $NETWORK_NAME >/dev/null 2>&1; then
    log_error "Rede $NETWORK_NAME não existe. Recriando..."
    docker network create --driver=overlay --attachable $NETWORK_NAME
  fi
  
  # Verificar volumes
  log_message "Verificando volumes..."
  for vol in "volume_swarm_shared" "volume_swarm_certificates"; do
    if ! docker volume ls | grep -q "$vol"; then
      log_error "Volume $vol não existe. Criando..."
      docker volume create --name $vol
    fi
  done
  
  # Recriar o volume do Portainer para garantir uma configuração limpa
  log_message "Recriando volume do Portainer para garantir configuração limpa..."
  docker volume rm -f portainer_data >/dev/null 2>&1 || true
  docker volume create --name portainer_data
  
  # Reiniciar stacks com problemas
  local restart_needed=false
  
  if ! docker stack ls | grep -q "traefik" || [[ "$(docker service ls --filter "name=traefik_traefik" --format "{{.Replicas}}")" != *"1/1"* ]]; then
    log_message "Reiniciando stack do Traefik..."
    docker stack rm traefik || true
    sleep 10
    install_traefik
    restart_needed=true
  fi
  
  if ! docker stack ls | grep -q "portainer" || [[ "$(docker service ls --filter "name=portainer_portainer" --format "{{.Replicas}}")" != *"1/1"* ]]; then
    log_message "Reiniciando stack do Portainer..."
    docker stack rm portainer || true
    sleep 10
    install_portainer
    restart_needed=true
  fi
  
  if [ "$restart_needed" = true ]; then
    log_message "Stacks reiniciados. Verificando novamente em 30 segundos..."
    sleep 30
    check_services
  else
    log_message "Diagnóstico concluído. Nenhuma ação adicional necessária."
  fi
}

# Função principal de execução
main() {
  # Verificar se a configuração já foi concluída
  log_message "Iniciando configuração do ambiente Swarm..."
  
  # Verificar se a configuração já foi concluída
  if [ -f "/root/.credentials/portainer.txt" ] && check_services; then
    log_message "Ambiente já parece estar configurado e funcionando."
    log_message "Reinstalando todos os serviços para garantir configuração atualizada..."
  fi
  
  update_system
  install_docker
  init_swarm
  check_dns
  install_traefik
  install_portainer
  
  # Verificar se tudo está funcionando
  if check_services; then
    log_message "Configuração concluída com sucesso!"
    log_message "Portainer está disponível em: https://${PORTAINER_DOMAIN}"
    log_message "IMPORTANTE: No primeiro acesso, você precisará definir uma senha para o admin"
    log_message "Senha sugerida: $(cat /root/.credentials/portainer_password.txt)"
    log_message "Credenciais salvas em: /root/.credentials/portainer.txt"
    
    # Enviar dados para o webhook
    send_webhook_with_logs "success" "Configuração do ambiente Docker Swarm concluída com sucesso"
  else
    log_error "Alguns serviços não estão funcionando corretamente."
    troubleshoot_services
    
    # Verificação final
    if check_services; then
      log_message "Todos os problemas foram resolvidos!"
      log_message "Configuração concluída com sucesso!"
      log_message "Portainer está disponível em: https://${PORTAINER_DOMAIN}"
      log_message "IMPORTANTE: No primeiro acesso, você precisará definir uma senha para o admin"
      log_message "Senha sugerida: $(cat /root/.credentials/portainer_password.txt)"
      log_message "Credenciais salvas em: /root/.credentials/portainer.txt"
      
      # Enviar dados para o webhook
      send_webhook_with_logs "success" "Configuração do ambiente Docker Swarm concluída com sucesso após troubleshooting"
    else
      log_error "Ainda existem problemas com os serviços."
      log_error "Verifique os logs em /var/log/swarm-setup.log e /var/log/traefik/"
      
      # Enviar dados para o webhook mesmo com problemas
      log_message "Enviando dados para o webhook mesmo com problemas..."
      send_webhook_with_logs "error" "Configuração do ambiente Docker Swarm concluída com problemas nos serviços"
      
      # Auto-responder com 's' para evitar interação humana
      log_message "Continuando mesmo assim para permitir automatização completa..."
    fi
  fi
}

# Captura de sinais para limpeza adequada
trap 'log_error "Script interrompido pelo usuário. Limpando..."; send_webhook_with_logs "error" "Script interrompido pelo usuário"; exit 1' INT TERM

# Executar a função principal
main

log_message "Instalação concluída!"
