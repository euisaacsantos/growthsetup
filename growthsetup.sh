#!/bin/bash
# Script para configuração de Docker Swarm, Portainer e Traefik com subdomínio personalizável
# Autor: Claude
# Data: 26/03/2025

set -e

# Cores para melhor visualização
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Função para exibir mensagens
log() {
  local msg="$1"
  local color="${2:-$GREEN}"
  echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] $msg${NC}"
}

# Verificar se está sendo executado como root
if [ "$EUID" -ne 0 ]; then
  log "Este script precisa ser executado como root." "$RED"
  exit 1
fi

# Verificar argumentos
if [ "$#" -lt 1 ]; then
  log "Uso: $0 <subdominio-portainer> [dominio-principal]" "$RED"
  log "Exemplo: $0 portainer exemplo.com" "$YELLOW"
  exit 1
fi

PORTAINER_SUBDOMAIN="$1"
DOMAIN="${2:-localhost}"
FULL_DOMAIN="${PORTAINER_SUBDOMAIN}.${DOMAIN}"

log "Configurando com Portainer em: ${FULL_DOMAIN}"

# Atualizar o sistema
update_system() {
  log "Atualizando o sistema..."
  apt update && apt upgrade -y
  apt install -y curl wget apt-transport-https ca-certificates software-properties-common gnupg
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
  apt install -y docker-ce docker-ce-cli containerd.io
  
  # Iniciar e habilitar o Docker
  systemctl enable --now docker
  
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
    docker swarm init --advertise-addr "$SERVER_IP"
    
    log "Docker Swarm inicializado com sucesso!"
  fi
  
  # Criar rede para os serviços
  if ! docker network ls | grep -q "traefik-public"; then
    docker network create --driver=overlay traefik-public
    log "Rede 'traefik-public' criada com sucesso!"
  else
    log "Rede 'traefik-public' já existe." "$YELLOW"
  fi
}

# Instalar e configurar Traefik
install_traefik() {
  log "Instalando Traefik..."
  
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
      email: admin@${DOMAIN}
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
  
  # Criar serviço Traefik no Swarm
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
    --label "traefik.http.routers.traefik-secure.tls.certresolver=letsencrypt" \
    --label "traefik.http.routers.traefik-secure.service=api@internal" \
    --label "traefik.http.routers.traefik-secure.middlewares=secure-headers" \
    --label "traefik.http.services.traefik.loadbalancer.server.port=8080" \
    traefik:latest
  
  log "Traefik instalado com sucesso!"
}

# Instalar e configurar Portainer
install_portainer() {
  log "Instalando Portainer com subdomínio: ${FULL_DOMAIN}..."
  
  # Gerar senha inicial para o admin
  ADMIN_PASSWORD=$(openssl rand -base64 12)
  ADMIN_PASSWORD_HASH=$(docker run --rm httpd:2.4-alpine htpasswd -nbB admin "$ADMIN_PASSWORD" | cut -d ":" -f 2)
  
  # Criar diretório para dados do Portainer
  mkdir -p /opt/portainer/data
  
  # Criar serviço Portainer no Swarm
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
    portainer/portainer-ce:latest \
    --admin-password-file <(echo -n $ADMIN_PASSWORD_HASH)
  
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

# Função principal de execução
main() {
  log "Iniciando configuração do ambiente..."
  
  update_system
  install_docker
  init_swarm
  install_traefik
  install_portainer
  
  log "Configuração concluída com sucesso!" "$GREEN"
  log "Portainer está disponível em: https://${FULL_DOMAIN}" "$GREEN"
  log "Credenciais salvas em: /root/.credentials/portainer.txt" "$GREEN"
}

# Iniciar a execução do script
main
