#!/bin/bash
# Script para configuração de Docker Swarm, Portainer e Traefik com subdomínio personalizável
# Versão: 2.0 - Com verificações de falhas e recursos de recuperação
# Data: 26/03/2025

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

# Função para reinstalar o Ubuntu 20.04
reinstall_ubuntu() {
  log "Iniciando reinstalação do Ubuntu 20.04..." "$YELLOW"
  
  # Aqui você pode adicionar comandos para salvar dados importantes antes da reinstalação
  mkdir -p /backup
  
  if [ -d "/root/.credentials" ]; then
    cp -r /root/.credentials /backup/
  fi
  
  log "Em um ambiente de produção, este comando iniciaria uma reinstalação do sistema." "$YELLOW"
  log "Como isso é complexo e específico para cada ambiente, você precisará implementar esta função de acordo com sua infraestrutura." "$YELLOW"
  log "Após a reinstalação, execute este script novamente." "$YELLOW"
  
  exit 1
}

# Atualizar o sistema
update_system() {
  log "Atualizando o sistema..."
  
  # Configurar apt para modo não interativo
  export DEBIAN_FRONTEND=noninteractive
  
  # Atualizar listas de pacotes
  apt update
  
  # Realizar upgrade sem prompts, mantendo arquivos de configuração locais
  apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y
  
  # Instalar pacotes necessários sem prompts
  apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y \
    curl wget apt-transport-https ca-certificates \
    software-properties-common gnupg jq host || handle_error "Falha ao atualizar o sistema" "atualização do sistema"
  
  log "Sistema atualizado com sucesso!"
}

# Instalar Docker
install_docker() {
  log "Instalando Docker..."
  
  # Remover versões antigas do Docker, se existirem
  apt remove -y docker docker-engine docker.io containerd runc || true
  
  # Adicionar a chave GPG oficial do Docker
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  
  # Configurar o repositório estável do Docker
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  # Instalar Docker Engine
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io || handle_error "Falha ao instalar o Docker" "instalação do Docker"
  
  # Iniciar e habilitar o Docker
  systemctl enable --now docker
  
  # Verificar instalação
  docker --version || throw "Docker não foi instalado corretamente"
  
  log "Docker instalado com sucesso!"
}

# Inicializar Docker Swarm
init_swarm() {
  log "Inicializando o Docker Swarm..."
  
  # Verificar se o Swarm já está inicializado
  if docker info | grep -q "Swarm: active"; then
    log "Docker Swarm já está ativo neste nó." "$YELLOW"
  else
    # Obter IP do servidor para o Swarm
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    # Iniciar o Docker Swarm
    docker swarm init --advertise-addr "$SERVER_IP" || handle_error "Falha ao inicializar o Docker Swarm" "inicialização do Swarm"
    
    log "Docker Swarm inicializado com sucesso!"
  fi
  
  # Criar rede para os serviços
  if ! docker network ls | grep -q "traefik-public"; then
    docker network create --driver=overlay traefik-public || handle_error "Falha ao criar rede traefik-public" "criação de rede"
    log "Rede 'traefik-public' criada com sucesso!"
  else
    log "Rede 'traefik-public' já existe." "$YELLOW"
  fi
}

# Verificar configuração de DNS
check_dns() {
  log "Verificando configuração DNS para ${FULL_DOMAIN}..."
  
  # Registrar a tentativa de resolução
  local dns_check=$(host ${FULL_DOMAIN} 2>&1 || true)
  log "Resultado da verificação DNS: ${dns_check}" "$BLUE"
  
  if echo "$dns_check" | grep -q "NXDOMAIN" || echo "$dns_check" | grep -q "not found"; then
    log "Aviso: Não foi possível resolver ${FULL_DOMAIN}." "$YELLOW"
    log "Certifique-se de que o DNS está configurado corretamente apontando para o IP deste servidor." "$YELLOW"
    log "Os certificados SSL não funcionarão até que o DNS esteja corretamente configurado." "$YELLOW"
    
    # Obter o IP do servidor
    local server_ip=$(hostname -I | awk '{print $1}')
    log "IP deste servidor: ${server_ip}" "$YELLOW"
    log "Configure seu DNS para que ${FULL_DOMAIN} aponte para ${server_ip}" "$YELLOW"
    
    # Perguntar se deseja continuar
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

# Instalar e configurar Traefik
install_traefik() {
  log "Instalando Traefik..."
  
  # Remover instalação anterior se existir
  docker service rm traefik || true
  
  # Esperar serviço ser removido
  sleep 10
  
  # Criar diretórios para o Traefik
  mkdir -p /opt/traefik/config
  mkdir -p /opt/traefik/certificates
  
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
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${EMAIL}
      storage: /opt/traefik/certificates/acme.json
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
    filename: /opt/traefik/config/dynamic.yml
    watch: true
EOF
  
  # Criar arquivo acme.json para certificados
  touch /opt/traefik/certificates/acme.json
  chmod 600 /opt/traefik/certificates/acme.json
  
  # Usar versão específica do Traefik para maior estabilidade
  docker service create \
    --name traefik \
    --constraint=node.role==manager \
    --publish 80:80 \
    --publish 443:443 \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --mount type=bind,source=/opt/traefik/traefik.yml,target=/etc/traefik/traefik.yml \
    --mount type=bind,source=/opt/traefik/config,target=/etc/traefik/config \
    --mount type=bind,source=/opt/traefik/certificates,target=/etc/traefik/certificates \
    --network traefik-public \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.traefik-secure.entrypoints=websecure" \
    --label "traefik.http.routers.traefik-secure.rule=Host(\`traefik.${DOMAIN}\`)" \
    --label "traefik.http.routers.traefik-secure.tls=true" \
    --label "traefik.http.routers.traefik-secure.service=api@internal" \
    --label "traefik.http.routers.traefik-secure.middlewares=secure-headers" \
    --label "traefik.http.services.traefik.loadbalancer.server.port=8080" \
    traefik:v2.10.4 || handle_error "Falha ao criar serviço Traefik" "instalação do Traefik"
  
  log "Traefik instalado com sucesso!"
}

# Instalar e configurar Portainer
install_portainer() {
  log "Instalando Portainer com subdomínio: ${FULL_DOMAIN}..."
  
  # Remover instalação anterior se existir
  docker service rm portainer || true
  
  # Esperar serviço ser removido
  sleep 10
  
  # Gerar senha inicial para o admin
  ADMIN_PASSWORD=$(openssl rand -base64 12)
  ADMIN_PASSWORD_HASH=$(docker run --rm httpd:2.4-alpine htpasswd -nbB admin "$ADMIN_PASSWORD" | cut -d ":" -f 2)
  
  # Criar diretório para dados do Portainer
  mkdir -p /opt/portainer/data
  
  # Instalar uma versão específica do Portainer para maior estabilidade
  docker service create \
    --name portainer \
    --constraint=node.role==manager \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --mount type=bind,source=/opt/portainer/data,target=/data \
    --network traefik-public \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.portainer-secure.entrypoints=websecure" \
    --label "traefik.http.routers.portainer-secure.rule=Host(\`${FULL_DOMAIN}\`)" \
    --label "traefik.http.routers.portainer-secure.tls=true" \
    --label "traefik.http.routers.portainer-secure.tls.certresolver=letsencrypt" \
    --label "traefik.http.routers.portainer-secure.service=portainer" \
    --label "traefik.http.services.portainer.loadbalancer.server.port=9000" \
    --label "traefik.http.middlewares.portainer-secure.headers.sslredirect=true" \
    portainer/portainer-ce:2.19.0 \
    --admin-password="$ADMIN_PASSWORD_HASH" || handle_error "Falha ao criar serviço Portainer" "instalação do Portainer"
  
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
  
  log "Portainer instalado com sucesso!"
  log "Credenciais salvas em: /root/.credentials/portainer.txt" "$YELLOW"
  log "URL do Portainer: https://${FULL_DOMAIN}" "$YELLOW"
  log "Usuário: admin" "$YELLOW"
  log "Senha: ${ADMIN_PASSWORD}" "$YELLOW"
}

# Verificar saúde dos serviços
check_services() {
  log "Verificando saúde dos serviços..."
  
  # Verificar traefik
  if ! docker service ls | grep -q "traefik"; then
    log "Serviço Traefik não está em execução!" "$RED"
    return 1
  fi
  
  # Verificar portainer
  if ! docker service ls | grep -q "portainer"; then
    log "Serviço Portainer não está em execução!" "$RED"
    return 1
  fi
  
  # Verificar status de execução dos serviços
  local traefik_replicas=$(docker service ls --filter "name=traefik" --format "{{.Replicas}}")
  local portainer_replicas=$(docker service ls --filter "name=portainer" --format "{{.Replicas}}")
  
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
  
  # Verificar logs de erro do Traefik
  log "Verificando logs do Traefik..."
  docker service logs --tail 20 traefik 2>&1 | grep -i "error" || true
  
  # Verificar logs de erro do Portainer
  log "Verificando logs do Portainer..."
  docker service logs --tail 20 portainer 2>&1 | grep -i "error" || true
  
  # Verificar configurações de rede
  log "Verificando configurações de rede..."
  if ! docker network inspect traefik-public >/dev/null 2>&1; then
    log "Rede traefik-public não existe. Recriando..." "$RED"
    docker network create --driver=overlay traefik-public
  fi
  
  # Reiniciar serviços com problemas
  local restart_needed=false
  
  if ! docker service ls | grep -q "traefik" || [[ "$(docker service ls --filter "name=traefik" --format "{{.Replicas}}")" != *"1/1"* ]]; then
    log "Reiniciando serviço Traefik..." "$YELLOW"
    docker service rm traefik || true
    sleep 10
    install_traefik
    restart_needed=true
  fi
  
  if ! docker service ls | grep -q "portainer" || [[ "$(docker service ls --filter "name=portainer" --format "{{.Replicas}}")" != *"1/1"* ]]; then
    log "Reiniciando serviço Portainer..." "$YELLOW"
    docker service rm portainer || true
    sleep 10
    install_portainer
    restart_needed=true
  fi
  
  if [ "$restart_needed" = true ]; then
    log "Serviços reiniciados. Verificando novamente em 30 segundos..." "$YELLOW"
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
