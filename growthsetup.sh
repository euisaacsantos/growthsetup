#!/bin/bash
# Script para configuração de Docker Swarm, Portainer e Traefik
# Versão: 7.0 - Solução final para o problema de login
# Data: 27/03/2025

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

# Função para exibir mensagens
log() {
  local msg="$1"
  local color="${2:-$GREEN}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${color}[${timestamp}] $msg${NC}" | tee -a "$LOG_FILE"
}

# Função para tratamento de erros
handle_error() {
  local error_msg="$1"
  local step="$2"
  local exit_code="${3:-1}"
  
  log "ERRO durante $step: $error_msg" "$RED"
  log "Verifique o log em $LOG_FILE para mais detalhes." "$RED"
  
  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log "Tentando novamente ($RETRY_COUNT/$MAX_RETRIES)..." "$YELLOW"
    sleep 5
    main
  else
    log "Número máximo de tentativas atingido." "$RED"
    log "Instalação abortada." "$RED"
    exit $exit_code
  fi
}

# Verificar se está sendo executado como root
if [ "$EUID" -ne 0 ]; then
  log "Este script precisa ser executado como root." "$RED"
  exit 1
fi

# Criar arquivo de log
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
log "Log iniciado em $LOG_FILE" "$BLUE"

# Verificar argumentos
if [ "$#" -lt 1 ]; then
  log "Uso: $0 <subdominio-portainer> [dominio-principal] [email]" "$RED"
  log "Exemplo: $0 portainer exemplo.com admin@exemplo.com" "$YELLOW"
  exit 1
fi

PORTAINER_SUBDOMAIN="$1"
DOMAIN="${2:-localhost}"
EMAIL="${3:-admin@$DOMAIN}"
PORTAINER_DOMAIN="${PORTAINER_SUBDOMAIN}.${DOMAIN}"

log "Configurando com Portainer em: ${PORTAINER_DOMAIN}"
log "Email para certificados SSL: ${EMAIL}"

# Atualizar o sistema
update_system() {
  log "Atualizando o sistema..."
  
  export DEBIAN_FRONTEND=noninteractive
  
  apt update
  
  apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y
  
  apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y \
    curl wget apt-transport-https ca-certificates \
    software-properties-common gnupg jq host || handle_error "Falha ao atualizar o sistema" "atualização do sistema"
  
  log "Sistema atualizado com sucesso!"
}

# Instalar Docker
install_docker() {
  log "Instalando Docker..."
  
  apt remove -y docker docker-engine docker.io containerd runc || true
  
  # Adicionar a chave GPG oficial do Docker (com tratamento para evitar prompts)
  if [ -f "/usr/share/keyrings/docker-archive-keyring.gpg" ]; then
    log "Arquivo de chave GPG do Docker já existe, removendo para atualizar..."
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
  fi
  
  # Usar redirecionamento para evitar prompts
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || handle_error "Falha ao instalar o Docker" "instalação do Docker"
  
  systemctl enable --now docker
  
  if ! docker --version; then
    log "Docker não foi instalado corretamente" "$RED"
    return 1
  fi
  
  log "Docker instalado com sucesso!"
}

# Inicializar Docker Swarm
init_swarm() {
  log "Inicializando o Docker Swarm..."
  
  if docker info | grep -q "Swarm: active"; then
    log "Docker Swarm já está ativo neste nó." "$YELLOW"
  else
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    docker swarm init --advertise-addr "$SERVER_IP" || handle_error "Falha ao inicializar o Docker Swarm" "inicialização do Swarm"
    
    log "Docker Swarm inicializado com sucesso!"
  fi
  
  # Criar rede para os serviços
  if ! docker network ls | grep -q "$NETWORK_NAME"; then
    docker network create --driver=overlay --attachable "$NETWORK_NAME" || handle_error "Falha ao criar rede $NETWORK_NAME" "criação de rede"
    log "Rede '$NETWORK_NAME' criada com sucesso!"
  else
    log "Rede '$NETWORK_NAME' já existe." "$YELLOW"
  fi
  
  # Criar volumes necessários
  log "Criando volumes necessários..."
  
  if ! docker volume ls | grep -q "volume_swarm_shared"; then
    docker volume create --name volume_swarm_shared || handle_error "Falha ao criar volume volume_swarm_shared" "criação de volume"
    log "Volume 'volume_swarm_shared' criado com sucesso!"
  else
    log "Volume 'volume_swarm_shared' já existe." "$YELLOW"
  fi
  
  if ! docker volume ls | grep -q "volume_swarm_certificates"; then
    docker volume create --name volume_swarm_certificates || handle_error "Falha ao criar volume volume_swarm_certificates" "criação de volume"
    log "Volume 'volume_swarm_certificates' criado com sucesso!"
  else
    log "Volume 'volume_swarm_certificates' já existe." "$YELLOW"
  fi
  
  # Remover e recriar volume do Portainer para garantir configuração limpa
  docker volume rm -f portainer_data >/dev/null 2>&1 || true
  docker volume create --name portainer_data || handle_error "Falha ao criar volume portainer_data" "criação de volume"
  log "Volume 'portainer_data' criado com sucesso!"
}

# Verificar configuração de DNS
check_dns() {
  log "Verificando configuração DNS para ${PORTAINER_DOMAIN}..."
  
  local dns_check=$(host ${PORTAINER_DOMAIN} 2>&1 || true)
  log "Resultado da verificação DNS: ${dns_check}" "$BLUE"
  
  if echo "$dns_check" | grep -q "NXDOMAIN" || echo "$dns_check" | grep -q "not found"; then
    log "Aviso: Não foi possível resolver ${PORTAINER_DOMAIN}." "$YELLOW"
    log "Certifique-se de que o DNS está configurado corretamente apontando para o IP deste servidor." "$YELLOW"
    log "Os certificados SSL não funcionarão até que o DNS esteja corretamente configurado." "$YELLOW"
    
    local server_ip=$(hostname -I | awk '{print $1}')
    log "IP deste servidor: ${server_ip}" "$YELLOW"
    log "Configure seu DNS para que ${PORTAINER_DOMAIN} aponte para ${server_ip}" "$YELLOW"
    
    log "Deseja continuar mesmo assim? (s/n)" "$YELLOW"
    read -r choice
    if [[ ! "$choice" =~ ^[Ss]$ ]]; then
      log "Instalação abortada pelo usuário." "$RED"
      exit 1
    fi
  else
    log "DNS para ${PORTAINER_DOMAIN} está configurado corretamente!" "$GREEN"
  fi
}

# Instalar e configurar Traefik usando docker-compose e stack
install_traefik() {
  log "Instalando Traefik usando Docker Stack..."
  
  # Remover instalação anterior se existir
  docker stack rm traefik || true
  
  # Esperar para serviço ser removido
  sleep 10
  
  # Criar diretório de log para Traefik
  mkdir -p /var/log/traefik
  chmod 755 /var/log/traefik
  
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
  docker stack deploy -c /opt/stacks/traefik/docker-compose.yml traefik || handle_error "Falha ao criar stack do Traefik" "implantação do Traefik"
  
  log "Stack do Traefik implantado com sucesso!"
}

# Gerar senha sugerida para o Portainer
generate_suggested_password() {
  # Gerar uma senha aleatória simples (letras e números apenas para evitar problemas)
  ADMIN_PASSWORD=$(openssl rand -base64 8 | tr -dc 'a-zA-Z0-9' | head -c 12)
  
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
  
  log "Senha sugerida para o Portainer: ${ADMIN_PASSWORD}" "$YELLOW"
  log "Credenciais salvas em /root/.credentials/portainer.txt" "$YELLOW"
}

# Instalar e configurar Portainer usando docker-compose e stack
install_portainer() {
  log "Instalando Portainer com domínio: ${PORTAINER_DOMAIN}..."
  
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
  docker stack deploy -c /opt/stacks/portainer/docker-compose.yml portainer || handle_error "Falha ao criar stack do Portainer" "implantação do Portainer"
  
  log "Stack do Portainer implantado com sucesso!"
  log "URL do Portainer: https://${PORTAINER_DOMAIN}" "$YELLOW"
  log "IMPORTANTE: No primeiro acesso, você precisará definir uma senha para o admin" "$YELLOW"
  log "Senha sugerida (salva em /root/.credentials/portainer.txt): $(cat /root/.credentials/portainer_password.txt)" "$YELLOW"
}

# Verificar saúde dos serviços
check_services() {
  log "Verificando saúde dos serviços..."
  
  # Verificar se os stacks estão em execução
  if ! docker stack ls | grep -q "traefik"; then
    log "Stack Traefik não está em execução!" "$RED"
    return 1
  fi
  
  if ! docker stack ls | grep -q "portainer"; then
    log "Stack Portainer não está em execução!" "$RED"
    return 1
  fi
  
  # Verificar status de execução dos serviços
  local traefik_replicas=$(docker service ls --filter "name=traefik_traefik" --format "{{.Replicas}}")
  local portainer_replicas=$(docker service ls --filter "name=portainer_portainer" --format "{{.Replicas}}")
  
  if [[ "$traefik_replicas" != *"1/1"* ]]; then
    log "Serviço Traefik não está saudável: $traefik_replicas" "$RED"
    return 1
  fi
  
  if [[ "$portainer_replicas" != *"1/1"* ]]; then
    log "Serviço Portainer não está saudável: $portainer_replicas" "$RED"
    return 1
  fi
  
  log "Todos os serviços estão saudáveis!" "$GREEN"
  return 0
}

# Função para fazer diagnóstico e correção automática
troubleshoot_services() {
  log "Iniciando diagnóstico de serviços..." "$BLUE"
  
  # Verificar sistema
  log "Verificando recursos do sistema..."
  local total_mem=$(free -m | awk '/^Mem:/{print $2}')
  local used_mem=$(free -m | awk '/^Mem:/{print $3}')
  local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
  
  if [ "$total_mem" -lt 2000 ]; then
    log "Aviso: Memória total ($total_mem MB) pode ser insuficiente para o Docker Swarm" "$YELLOW"
  fi
  
  if [ "$disk_usage" -gt 85 ]; then
    log "Aviso: Uso de disco ($disk_usage%) está alto" "$YELLOW"
  fi
  
  # Verificar Docker
  log "Verificando status do Docker..."
  if ! systemctl is-active --quiet docker; then
    log "Docker não está rodando. Tentando reiniciar..." "$RED"
    systemctl restart docker
    sleep 5
  fi
  
  # Limpar recursos não usados
  log "Limpando recursos Docker não utilizados..."
  docker system prune -f
  
  # Verificar logs do Traefik
  log "Verificando logs do Traefik..."
  docker service logs --tail 20 traefik_traefik 2>&1 | grep -i "error" || true
  
  # Verificar logs do Portainer
  log "Verificando logs do Portainer..."
  docker service logs --tail 20 portainer_portainer 2>&1 | grep -i "error" || true
  
  # Verificar configurações de rede
  log "Verificando configurações de rede..."
  if ! docker network inspect $NETWORK_NAME >/dev/null 2>&1; then
    log "Rede $NETWORK_NAME não existe. Recriando..." "$RED"
    docker network create --driver=overlay --attachable $NETWORK_NAME
  fi
  
  # Verificar volumes
  log "Verificando volumes..."
  for vol in "volume_swarm_shared" "volume_swarm_certificates"; do
    if ! docker volume ls | grep -q "$vol"; then
      log "Volume $vol não existe. Criando..." "$RED"
      docker volume create --name $vol
    fi
  done
  
  # Recriar o volume do Portainer para garantir uma configuração limpa
  log "Recriando volume do Portainer para garantir configuração limpa..."
  docker volume rm -f portainer_data >/dev/null 2>&1 || true
  docker volume create --name portainer_data
  
  # Reiniciar stacks com problemas
  local restart_needed=false
  
  if ! docker stack ls | grep -q "traefik" || [[ "$(docker service ls --filter "name=traefik_traefik" --format "{{.Replicas}}")" != *"1/1"* ]]; then
    log "Reiniciando stack do Traefik..." "$YELLOW"
    docker stack rm traefik || true
    sleep 10
    install_traefik
    restart_needed=true
  fi
  
  if ! docker stack ls | grep -q "portainer" || [[ "$(docker service ls --filter "name=portainer_portainer" --format "{{.Replicas}}")" != *"1/1"* ]]; then
    log "Reiniciando stack do Portainer..." "$YELLOW"
    docker stack rm portainer || true
    sleep 10
    install_portainer
    restart_needed=true
  fi
  
  if [ "$restart_needed" = true ]; then
    log "Stacks reiniciados. Verificando novamente em 30 segundos..." "$YELLOW"
    sleep 30
    check_services
  else
    log "Diagnóstico concluído. Nenhuma ação adicional necessária." "$GREEN"
  fi
}

# Função principal de execução
main() {
  # Verificar se a configuração já foi concluída
  log "Iniciando configuração do ambiente Swarm..."
  
  # Verificar se a configuração já foi concluída
  if [ -f "/root/.credentials/portainer.txt" ] && check_services; then
    log "Ambiente já parece estar configurado e funcionando." "$YELLOW"
    log "Deseja reinstalar todos os serviços? (s/n)" "$YELLOW"
    # Responder automaticamente "sim" para permitir execução sem intervenção
    echo "s"
  fi
  
  update_system
  install_docker
  init_swarm
  
  # Auto-responder 's' para pergunta do check_dns
  check_dns << EOF
s
EOF
  
  install_traefik
  install_portainer
  
  # Verificar se tudo está funcionando
  if check_services; then
    log "Configuração concluída com sucesso!" "$GREEN"
    log "Portainer está disponível em: https://${PORTAINER_DOMAIN}" "$GREEN"
    log "IMPORTANTE: No primeiro acesso, você precisará definir uma senha para o admin" "$YELLOW"
    log "Senha sugerida: $(cat /root/.credentials/portainer_password.txt)" "$GREEN"
    log "Credenciais salvas em: /root/.credentials/portainer.txt" "$GREEN"
  else
    log "Alguns serviços não estão funcionando corretamente." "$RED"
    troubleshoot_services
    
    # Verificação final
    if check_services; then
      log "Todos os problemas foram resolvidos!" "$GREEN"
      log "Configuração concluída com sucesso!" "$GREEN"
      log "Portainer está disponível em: https://${PORTAINER_DOMAIN}" "$GREEN"
      log "IMPORTANTE: No primeiro acesso, você precisará definir uma senha para o admin" "$YELLOW"
      log "Senha sugerida: $(cat /root/.credentials/portainer_password.txt)" "$GREEN"
      log "Credenciais salvas em: /root/.credentials/portainer.txt" "$GREEN"
    else
      log "Ainda existem problemas com os serviços." "$RED"
      log "Verifique os logs em /var/log/swarm-setup.log e /var/log/traefik/" "$RED"
      # Auto-responder com 's' para evitar interação humana
      log "Continuar mesmo assim? (s/n)" "$YELLOW"
      log "Auto-respondendo 's' para permitir automatização completa" "$BLUE"
      # Isso faz com que o script continue sem interação humana
      exec < <(echo "s")
    fi
  fi
}

# Captura de sinais para limpeza adequada
trap 'log "Script interrompido pelo usuário. Limpando..."; exit 1' INT TERM

# Executar a função principal
main
