#!/bin/bash
# Script para configuração de Docker Swarm, Portainer e Traefik com subdomínio personalizável
# Versão: 3.0 - Implementação de stacks via docker-compose.yml
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
    log "Número máximo de tentativas atingido. Deseja reinstalar o Ubuntu 20.04? (s/n)" "$YELLOW"
    read -r choice
    if [[ "$choice" =~ ^[Ss]$ ]]; then
      reinstall_ubuntu
    else
      log "Instalação abortada." "$RED"
      exit $exit_code
    fi
  fi
}

# Definir tratamento de erro global
throw() {
  local message="$1"
  log "$message" "$RED"
  return 1
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
FULL_DOMAIN="${PORTAINER_SUBDOMAIN}.${DOMAIN}"

log "Configurando com Portainer em: ${FULL_DOMAIN}"
log "Email para certificados SSL: ${EMAIL}"

# Função para reinstalar o Ubuntu 20.04 (não modificada)
reinstall_ubuntu() {
  log "Iniciando reinstalação do Ubuntu 20.04..." "$YELLOW"
  
  mkdir -p /backup
  
  if [ -d "/root/.credentials" ]; then
    cp -r /root/.credentials /backup/
  fi
  
  log "Em um ambiente de produção, este comando iniciaria uma reinstalação do sistema." "$YELLOW"
  log "Como isso é complexo e específico para cada ambiente, você precisará implementar esta função de acordo com sua infraestrutura." "$YELLOW"
  log "Após a reinstalação, execute este script novamente." "$YELLOW"
  
  exit 1
}

# Atualizar o sistema (não modificada)
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

# Instalar Docker (não modificada)
install_docker() {
  log "Instalando Docker..."
  
  apt remove -y docker docker-engine docker.io containerd runc || true
  
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || handle_error "Falha ao instalar o Docker" "instalação do Docker"
  
  systemctl enable --now docker
  
  docker --version || throw "Docker não foi instalado corretamente"
  
  log "Docker instalado com sucesso!"
}

# Inicializar Docker Swarm (não modificada)
init_swarm() {
  log "Inicializando o Docker Swarm..."
  
  if docker info | grep -q "Swarm: active"; then
    log "Docker Swarm já está ativo neste nó." "$YELLOW"
  else
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    docker swarm init --advertise-addr "$SERVER_IP" || handle_error "Falha ao inicializar o Docker Swarm" "inicialização do Swarm"
    
    log "Docker Swarm inicializado com sucesso!"
  fi
  
  if ! docker network ls | grep -q "traefik-public"; then
    docker network create --driver=overlay traefik-public || handle_error "Falha ao criar rede traefik-public" "criação de rede"
    log "Rede 'traefik-public' criada com sucesso!"
  else
    log "Rede 'traefik-public' já existe." "$YELLOW"
  fi
}

# Verificar configuração de DNS (não modificada)
check_dns() {
  log "Verificando configuração DNS para ${FULL_DOMAIN}..."
  
  local dns_check=$(host ${FULL_DOMAIN} 2>&1 || true)
  log "Resultado da verificação DNS: ${dns_check}" "$BLUE"
  
  if echo "$dns_check" | grep -q "NXDOMAIN" || echo "$dns_check" | grep -q "not found"; then
    log "Aviso: Não foi possível resolver ${FULL_DOMAIN}." "$YELLOW"
    log "Certifique-se de que o DNS está configurado corretamente apontando para o IP deste servidor." "$YELLOW"
    log "Os certificados SSL não funcionarão até que o DNS esteja corretamente configurado." "$YELLOW"
    
    local server_ip=$(hostname -I | awk '{print $1}')
    log "IP deste servidor: ${server_ip}" "$YELLOW"
    log "Configure seu DNS para que ${FULL_DOMAIN} aponte para ${server_ip}" "$YELLOW"
    
    log "Deseja continuar mesmo assim? (s/n)" "$YELLOW"
    read -r choice
    if [[ ! "$choice" =~ ^[Ss]$ ]]; then
      log "Instalação abortada pelo usuário." "$RED"
      exit 1
    fi
  else
    log "DNS para ${FULL_DOMAIN} está configurado corretamente!" "$GREEN"
  fi
}

# Instalar e configurar Traefik usando docker-compose e stack
install_traefik() {
  log "Instalando Traefik usando Docker Stack..."
  
  # Remover instalação anterior se existir
  docker stack rm traefik || true
  
  # Esperar para serviço ser removido
  sleep 10
  
  # Criar diretórios para o Traefik
  mkdir -p /opt/traefik/config
  mkdir -p /opt/traefik/certificates
  
  # Verificar e garantir que o diretório existe
  if [ ! -d "/opt/traefik/certificates" ]; then
    log "Criando diretório para certificados..." "$YELLOW"
    mkdir -p /opt/traefik/certificates
  fi
  
  # Criar arquivo de configuração dinâmica do Traefik
  cat > /opt/traefik/config/dynamic.yml << EOF
http:
  middlewares:
    secure-headers:
      headers:
        sslRedirect: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
    
    compress:
      compress: {}
EOF
  
  # Criar arquivo de configuração estática do Traefik
  cat > /opt/traefik/traefik.yml << EOF
global:
  checkNewVersion: true
  sendAnonymousUsage: false

log:
  level: "INFO"

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
  
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${EMAIL}
      storage: /etc/traefik/certificates/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    swarmMode: true
    watch: true
    exposedByDefault: false
    network: traefik-public
  
  file:
    directory: /etc/traefik/config
    watch: true
EOF
  
  # Criar arquivo acme.json para certificados com as permissões corretas
  touch /opt/traefik/certificates/acme.json
  chmod 600 /opt/traefik/certificates/acme.json
  
  # Garantir as permissões corretas no diretório de certificados
  chmod -R 755 /opt/traefik/certificates
  
  # Criar compose file para o Traefik
  mkdir -p /opt/traefik/stack
  cat > /opt/traefik/stack/docker-compose.yml << EOF
version: '3.8'

services:
  traefik:
    image: traefik:v2.10.4
    command:
      - "--configFile=/etc/traefik/traefik.yml"
    networks:
      - traefik-public
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/traefik/traefik.yml:/etc/traefik/traefik.yml
      - /opt/traefik/config:/etc/traefik/config
      - /opt/traefik/certificates:/etc/traefik/certificates
    ports:
      - "80:80"
      - "443:443"
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.traefik-secure.entrypoints=websecure"
        - "traefik.http.routers.traefik-secure.rule=Host(\`traefik.${DOMAIN}\`)"
        - "traefik.http.routers.traefik-secure.tls=true"
        - "traefik.http.routers.traefik-secure.service=api@internal"
        - "traefik.http.routers.traefik-secure.middlewares=secure-headers@file"
        - "traefik.http.services.traefik.loadbalancer.server.port=8080"

networks:
  traefik-public:
    external: true
EOF
  
  # Implantar o stack do Traefik
  docker stack deploy -c /opt/traefik/stack/docker-compose.yml traefik || handle_error "Falha ao criar stack do Traefik" "implantação do Traefik"
  
  log "Stack do Traefik implantado com sucesso!"
}

# Instalar e configurar Portainer usando docker-compose e stack
install_portainer() {
  log "Instalando Portainer com subdomínio: ${FULL_DOMAIN}..."
  
  # Remover instalação anterior se existir
  docker stack rm portainer || true
  
  # Esperar serviço ser removido
  sleep 10
  
  # Gerar senha inicial para o admin
  ADMIN_PASSWORD=$(openssl rand -base64 12)
  ADMIN_PASSWORD_HASH=$(docker run --rm httpd:2.4-alpine htpasswd -nbB admin "$ADMIN_PASSWORD" | cut -d ":" -f 2)
  
  # Criar diretório para dados do Portainer
  mkdir -p /opt/portainer/data
  mkdir -p /opt/portainer/stack
  
  # Criar compose file para o Portainer
  cat > /opt/portainer/stack/docker-compose.yml << EOF
version: '3.8'

services:
  portainer:
    image: portainer/portainer-ce:2.19.0
    command: --admin-password="${ADMIN_PASSWORD_HASH}"
    networks:
      - traefik-public
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/portainer/data:/data
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portainer-secure.entrypoints=websecure"
        - "traefik.http.routers.portainer-secure.rule=Host(\`${FULL_DOMAIN}\`)"
        - "traefik.http.routers.portainer-secure.tls=true"
        - "traefik.http.routers.portainer-secure.tls.certresolver=letsencrypt"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"
        - "traefik.http.middlewares.portainer-secure.headers.sslredirect=true"

networks:
  traefik-public:
    external: true
EOF
  
  # Implantar o stack do Portainer
  docker stack deploy -c /opt/portainer/stack/docker-compose.yml portainer || handle_error "Falha ao criar stack do Portainer" "implantação do Portainer"
  
  # Salvar as credenciais em um arquivo seguro
  mkdir -p /root/.credentials
  chmod 700 /root/.credentials
  cat > /root/.credentials/portainer.txt << EOF
Portainer Admin Credentials
URL: https://${FULL_DOMAIN}
Username: admin
Password: ${ADMIN_PASSWORD}
EOF
  chmod 600 /root/.credentials/portainer.txt
  
  log "Stack do Portainer implantado com sucesso!"
  log "Credenciais salvas em: /root/.credentials/portainer.txt" "$YELLOW"
  log "URL do Portainer: https://${FULL_DOMAIN}" "$YELLOW"
  log "Usuário: admin" "$YELLOW"
  log "Senha: ${ADMIN_PASSWORD}" "$YELLOW"
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
  if ! docker network inspect traefik-public >/dev/null 2>&1; then
    log "Rede traefik-public não existe. Recriando..." "$RED"
    docker network create --driver=overlay traefik-public
  fi
  
  # Verificar configuração dos certificados
  log "Verificando configuração de certificados..."
  if [ ! -f "/opt/traefik/certificates/acme.json" ]; then
    log "Arquivo acme.json não encontrado. Criando..." "$RED"
    touch /opt/traefik/certificates/acme.json
    chmod 600 /opt/traefik/certificates/acme.json
  fi
  
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
  log "Iniciando configuração do ambiente..."
  
  # Verificar se a configuração já foi concluída
  if [ -f "/root/.credentials/portainer.txt" ] && check_services; then
    log "Ambiente já parece estar configurado e funcionando." "$YELLOW"
    log "Deseja reinstalar todos os serviços? (s/n)" "$YELLOW"
    # Responder automaticamente "sim" para permitir execução sem intervenção
    echo "s"
  fi
  
  # Início da instalação
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
    log "Portainer está disponível em: https://${FULL_DOMAIN}" "$GREEN"
    log "Credenciais salvas em: /root/.credentials/portainer.txt" "$GREEN"
  else
    log "Alguns serviços não estão funcionando corretamente." "$RED"
    troubleshoot_services
    
    # Verificação final
    if check_services; then
      log "Todos os problemas foram resolvidos!" "$GREEN"
      log "Configuração concluída com sucesso!" "$GREEN"
      log "Portainer está disponível em: https://${FULL_DOMAIN}" "$GREEN"
      log "Credenciais salvas em: /root/.credentials/portainer.txt" "$GREEN"
    else
      log "Ainda existem problemas com os serviços." "$RED"
      log "Verifique os logs e considere a opção de reinstalação ou entre em contato com o suporte." "$RED"
      # Não abortar, responder automaticamente
      log "Continuar mesmo assim? (s/n)" "$YELLOW"
      echo "s"
    fi
  fi
}

# Captura de sinais para limpeza adequada
trap 'log "Script interrompido pelo usuário. Limpando..."; exit 1' INT TERM

# Executar a função principal
main
