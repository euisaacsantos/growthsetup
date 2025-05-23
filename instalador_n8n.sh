#!/bin/bash
# Script para criar stacks separadas para n8n no Portainer (n8n, Redis e PostgreSQL)
# Uso: ./script.sh <portainer_url> <n8n_editor_domain> <n8n_webhook_domain> <portainer_password> [sufixo] [id-xxxx]
# Exemplo: ./script.sh painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 cliente1 id-12341221125
# Sem sufixo: ./script.sh painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 "" id-12341221125

# Inicializar captura de logs
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
}

# Função para adicionar ao log de erro
log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local error_entry="[$timestamp] ERROR: $message"
    echo -e "\e[31m$error_entry\e[0m" >&2
    ERROR_LOG+="$error_entry\n"
    INSTALL_STATUS="error"
}

# Função para enviar webhook com logs
send_webhook_with_logs() {
    local final_status="$1"
    local final_message="$2"
    
    # Escapar caracteres especiais para JSON
    local escaped_install_log=$(echo -e "$INSTALL_LOG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n')
    local escaped_error_log=$(echo -e "$ERROR_LOG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n')
    
    # Preparar os dados para o webhook
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local hostname=$(hostname)
    local server_ip=$(hostname -I | awk '{print $1}')
    
    # Criar objeto JSON para o webhook com logs
    local WEBHOOK_DATA=$(cat << EOF
{
  "installation_id": "${INSTALLATION_ID}",
  "timestamp": "${timestamp}",
  "hostname": "${hostname}",
  "server_ip": "${server_ip}",
  "status": "${final_status}",
  "message": "${final_message}",
  "install_log": "${escaped_install_log}",
  "error_log": "${escaped_error_log}",
  "link": "https://${N8N_EDITOR_DOMAIN}",
  "password": "${N8N_SUGGESTED_PASSWORD}",
  "n8n": {
    "editor_domain": "${N8N_EDITOR_DOMAIN}",
    "webhook_domain": "${N8N_WEBHOOK_DOMAIN}",
    "encryption_key": "${N8N_ENCRYPTION_KEY}",
    "database_uri": "postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/n8n_queue${SUFFIX}"
  },
  "stacks": {
    "redis": "${REDIS_STACK_NAME}",
    "postgres": "${PG_STACK_NAME}",
    "n8n": "${N8N_STACK_NAME}"
  },
  "suffix": "${SUFFIX}"
}
EOF
)

    # Enviar dados para o webhook
    log_message "Enviando dados da instalação para o webhook..."
    local WEBHOOK_RESPONSE=$(curl -s -X POST "${WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "${WEBHOOK_DATA}" \
      -w "\n%{http_code}")

    local HTTP_CODE=$(echo "$WEBHOOK_RESPONSE" | tail -n1)
    local WEBHOOK_BODY=$(echo "$WEBHOOK_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 202 ]; then
        log_message "Dados enviados com sucesso para o webhook."
    else
        log_error "Não foi possível enviar os dados para o webhook. Código HTTP: ${HTTP_CODE}. Resposta: ${WEBHOOK_BODY}"
    fi
}

# Função para exibir erros e sair
error_exit() {
    log_error "$1"
    send_webhook_with_logs "error" "$1"
    exit 1
}

# Iniciar o log da instalação
log_message "Iniciando instalação do n8n..."

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    error_exit "Parâmetros insuficientes. Uso: $0 <portainer_url> <n8n_editor_domain> <n8n_webhook_domain> <portainer_password> [sufixo] [id-xxxx]"
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
N8N_EDITOR_DOMAIN="$2"               # Domínio para o editor n8n
N8N_WEBHOOK_DOMAIN="$3"              # Domínio para webhook n8n
PORTAINER_PASSWORD="$4"              # Senha do Portainer

log_message "Parâmetros recebidos: Portainer=$1, Editor=${N8N_EDITOR_DOMAIN}, Webhook=${N8N_WEBHOOK_DOMAIN}"

# Inicializar variáveis
SUFFIX=""
INSTALLATION_ID="sem_id"
WEBHOOK_URL="https://setup.growthtap.com.br/webhook/bf813e80-f036-400b-acae-904d703df6dd"

# Processar parâmetros opcionais (sufixo e ID)
for param in "${@:5}"; do
    # Verificar se o parâmetro começa com 'id-'
    if [[ "$param" == id-* ]]; then
        INSTALLATION_ID="${param#id-}"  # Remover o prefixo 'id-'
        log_message "ID da instalação: $INSTALLATION_ID"
    # Se não for vazio e não começar com 'id-', é o sufixo
    elif [ -n "$param" ]; then
        SUFFIX="_$param"
        log_message "Instalando com sufixo: $SUFFIX"
    fi
done

# Configurações adicionais
PORTAINER_USER="admin"              # Usuário do Portainer
N8N_STACK_NAME="n8n${SUFFIX}"       # Nome da stack n8n

# Nomes únicos para as stacks do Redis e PostgreSQL (prefixados com n8n_)
REDIS_STACK_NAME="n8n_redis${SUFFIX}"   # Nome da stack Redis com prefixo n8n_
PG_STACK_NAME="n8n_postgres${SUFFIX}"   # Nome da stack PostgreSQL com prefixo n8n_

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Verificar se já existe uma chave de criptografia no volume n8n_data
log_message "Verificando se já existe uma chave de criptografia..."
EXISTING_KEY=""

# Tenta extrair a chave existente de um container temporário
if docker volume inspect n8n_data${SUFFIX} &>/dev/null; then
    log_message "Volume n8n_data${SUFFIX} já existe. Tentando extrair a chave existente..."
    
    # Criar um container temporário para acessar o arquivo de configuração
    docker run --rm -v n8n_data${SUFFIX}:/data alpine:latest sh -c "if [ -f /data/.n8n/config ]; then cat /data/.n8n/config | grep -o '\"encryptionKey\":\"[^\"]*\"' | cut -d '\"' -f 4; fi" > /tmp/existing_key_output.txt
    
    EXISTING_KEY=$(cat /tmp/existing_key_output.txt)
    rm -f /tmp/existing_key_output.txt
    
    if [ -n "$EXISTING_KEY" ]; then
        log_message "Chave de criptografia existente encontrada. Usando-a em vez de gerar uma nova."
        N8N_ENCRYPTION_KEY=$EXISTING_KEY
    else
        log_message "Não foi possível extrair a chave existente ou o arquivo de configuração não existe."
        log_message "Gerando uma nova chave de criptografia..."
        N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
    fi
else
    log_message "Volume n8n_data${SUFFIX} não existe. Gerando uma nova chave de criptografia..."
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
fi

log_message "Chave de criptografia do n8n: ${N8N_ENCRYPTION_KEY}"

# Gerar uma senha sugerida para o n8n que atenda aos critérios (8+ caracteres, pelo menos 1 número e 1 letra maiúscula)
generate_valid_password() {
    while true; do
        # Gerar senha de 12 caracteres com letras e números
        password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
        
        # Verificar se a senha contém pelo menos um número
        if ! echo "$password" | grep -q '[0-9]'; then
            continue
        fi
        
        # Verificar se a senha contém pelo menos uma letra maiúscula
        if ! echo "$password" | grep -q '[A-Z]'; then
            continue
        fi
        
        # Se chegou aqui, a senha atende aos critérios
        echo "$password"
        break
    done
}

N8N_SUGGESTED_PASSWORD=$(generate_valid_password)
log_message "Senha sugerida para o n8n: ${N8N_SUGGESTED_PASSWORD}"

# Gerar uma senha do PostgreSQL aleatória
POSTGRES_PASSWORD=$(openssl rand -hex 16)
log_message "Senha do PostgreSQL gerada: ${POSTGRES_PASSWORD}"

# Criar volumes Docker necessários
log_message "Criando volumes Docker..."
docker volume create n8n_data${SUFFIX} 2>/dev/null || log_message "Volume n8n_data${SUFFIX} já existe."
docker volume create n8n_postgres_data${SUFFIX} 2>/dev/null || log_message "Volume n8n_postgres_data${SUFFIX} já existe."
docker volume create n8n_redis_data${SUFFIX} 2>/dev/null || log_message "Volume n8n_redis_data${SUFFIX} já existe."

# Verificar se a rede GrowthNet existe, caso contrário, criar
if ! docker network inspect GrowthNet >/dev/null 2>&1; then
    log_message "Criando rede GrowthNet..."
    # Criar a rede como attachable para permitir conexão direta para testes
    if docker network create --driver overlay --attachable GrowthNet; then
        log_message "Rede GrowthNet criada com sucesso."
    else
        log_error "Falha ao criar a rede GrowthNet."
    fi
else
    log_message "Rede GrowthNet já existe."
fi

# Criar arquivo docker-compose para a stack Redis
log_message "Criando arquivo docker-compose para a stack Redis..."
cat > "${REDIS_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  redis:
    image: redis:latest
    command: redis-server --appendonly yes
    volumes:
      - n8n_redis_data${SUFFIX}:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  n8n_redis_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack PostgreSQL
log_message "Criando arquivo docker-compose para a stack PostgreSQL..."
cat > "${PG_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  postgres:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=postgres
      # Inicializa o banco de dados necessário para o n8n
      - POSTGRES_DB=n8n_queue${SUFFIX}
    volumes:
      - n8n_postgres_data${SUFFIX}:/var/lib/postgresql/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  n8n_postgres_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack n8n
log_message "Criando arquivo docker-compose para a stack n8n..."
cat > "${N8N_STACK_NAME}.yaml" <<EOL
version: "3.7"
services:

## --------------------------- n8n Editor --------------------------- ##

  n8n_editor:
    image: n8nio/n8n:latest
    command: start
    networks:
      - GrowthNet
    environment:
      # Dados do postgres
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=n8n_queue${SUFFIX}
      - DB_POSTGRESDB_HOST=${PG_STACK_NAME}_postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

      # Payload size (valor maior para uploads)
      - N8N_PAYLOAD_SIZE_MAX=67108864

      # Encryption Key
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

      # Url do N8N
      - N8N_HOST=${N8N_EDITOR_DOMAIN}
      - N8N_EDITOR_BASE_URL=https://${N8N_EDITOR_DOMAIN}/
      - WEBHOOK_URL=https://${N8N_WEBHOOK_DOMAIN}/
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - NODE_BASE_URL=https://${N8N_EDITOR_DOMAIN}

      # Modo do Node
      - NODE_ENV=production

      # Modo de execução
      - EXECUTIONS_MODE=queue

      # Community Nodes
      - N8N_REINSTALL_MISSING_PACKAGES=true
      - N8N_COMMUNITY_PACKAGES_ENABLED=true
      - N8N_NODE_PATH=/home/node/.n8n/nodes

      # Dados do Redis
      - QUEUE_BULL_REDIS_HOST=${REDIS_STACK_NAME}_redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=2
      - NODE_FUNCTION_ALLOW_EXTERNAL=moment,lodash,moment-with-locales
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=48

      # Timezone
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - TZ=America/Sao_Paulo
    volumes:
      - n8n_data${SUFFIX}:/home/node/.n8n
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "1"
          memory: 1024M
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3
      labels:
        - traefik.enable=true
        - traefik.docker.network=GrowthNet
        - "traefik.http.routers.n8n_editor${SUFFIX}.rule=Host(\`${N8N_EDITOR_DOMAIN}\`)"
        - traefik.http.routers.n8n_editor${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.n8n_editor${SUFFIX}.tls=true
        - traefik.http.routers.n8n_editor${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.n8n_editor${SUFFIX}.priority=1
        - traefik.http.routers.n8n_editor${SUFFIX}.service=n8n_editor${SUFFIX}
        - traefik.http.services.n8n_editor${SUFFIX}.loadbalancer.server.port=5678
        - traefik.http.services.n8n_editor${SUFFIX}.loadbalancer.passHostHeader=1

## --------------------------- n8n Webhook --------------------------- ##

  n8n_webhook:
    image: n8nio/n8n:latest
    command: webhook
    networks:
      - GrowthNet
    environment:
      # Dados do postgres
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=n8n_queue${SUFFIX}
      - DB_POSTGRESDB_HOST=${PG_STACK_NAME}_postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

      # Payload size (valor maior para uploads)
      - N8N_PAYLOAD_SIZE_MAX=67108864

      # Encryption Key
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

      # Url do N8N
      - N8N_HOST=${N8N_EDITOR_DOMAIN}
      - N8N_EDITOR_BASE_URL=https://${N8N_EDITOR_DOMAIN}/
      - WEBHOOK_URL=https://${N8N_WEBHOOK_DOMAIN}/
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - NODE_BASE_URL=https://${N8N_EDITOR_DOMAIN}

      # Modo do Node
      - NODE_ENV=production

      # Modo de execução
      - EXECUTIONS_MODE=queue

      # Community Nodes
      - N8N_REINSTALL_MISSING_PACKAGES=true
      - N8N_COMMUNITY_PACKAGES_ENABLED=true
      - N8N_NODE_PATH=/home/node/.n8n/nodes

      # Dados do Redis
      - QUEUE_BULL_REDIS_HOST=${REDIS_STACK_NAME}_redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=2
      - NODE_FUNCTION_ALLOW_EXTERNAL=moment,lodash,moment-with-locales
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=336

      # Timezone
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - TZ=America/Sao_Paulo
    volumes:
      - n8n_data${SUFFIX}:/home/node/.n8n      
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "1"
          memory: 1024M
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3
      labels:
        - traefik.enable=true
        - traefik.docker.network=GrowthNet
        - "traefik.http.routers.n8n_webhook${SUFFIX}.rule=Host(\`${N8N_WEBHOOK_DOMAIN}\`)"
        - traefik.http.routers.n8n_webhook${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.n8n_webhook${SUFFIX}.tls=true
        - traefik.http.routers.n8n_webhook${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.n8n_webhook${SUFFIX}.priority=1
        - traefik.http.routers.n8n_webhook${SUFFIX}.service=n8n_webhook${SUFFIX}
        - traefik.http.services.n8n_webhook${SUFFIX}.loadbalancer.server.port=5678
        - traefik.http.services.n8n_webhook${SUFFIX}.loadbalancer.passHostHeader=1

## --------------------------- n8n Worker --------------------------- ##

  n8n_worker:
    image: n8nio/n8n:latest
    command: worker --concurrency=10
    networks:
      - GrowthNet
    environment:
      # Dados do postgres
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=n8n_queue${SUFFIX}
      - DB_POSTGRESDB_HOST=${PG_STACK_NAME}_postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

      # Payload size (valor maior para uploads)
      - N8N_PAYLOAD_SIZE_MAX=67108864

      # Encryption Key
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

      # Url do N8N
      - N8N_HOST=${N8N_EDITOR_DOMAIN}
      - N8N_EDITOR_BASE_URL=https://${N8N_EDITOR_DOMAIN}/
      - WEBHOOK_URL=https://${N8N_WEBHOOK_DOMAIN}/
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - NODE_BASE_URL=https://${N8N_EDITOR_DOMAIN}

      # Modo do Node
      - NODE_ENV=production

      # Modo de execução
      - EXECUTIONS_MODE=queue

      # Community Nodes
      - N8N_REINSTALL_MISSING_PACKAGES=true
      - N8N_COMMUNITY_PACKAGES_ENABLED=true
      - N8N_NODE_PATH=/home/node/.n8n/nodes

      # Dados do Redis
      - QUEUE_BULL_REDIS_HOST=${REDIS_STACK_NAME}_redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=2
      - NODE_FUNCTION_ALLOW_EXTERNAL=moment,lodash,moment-with-locales
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=336

      # Timezone
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - TZ=America/Sao_Paulo
    volumes:
      - n8n_data${SUFFIX}:/home/node/.n8n
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: "1"
          memory: 1024M
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  n8n_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Verificar se jq está instalado
log_message "Verificando se jq está instalado..."
if ! command -v jq &> /dev/null; then
    log_message "Instalando jq..."
    if apt-get update && apt-get install -y jq; then
        log_message "jq instalado com sucesso."
    else
        error_exit "Falha ao instalar jq. Necessário para processamento de JSON."
    fi
else
    log_message "jq já está instalado."
fi

# Obter token JWT do Portainer
log_message "Autenticando no Portainer..."
log_message "URL do Portainer: ${PORTAINER_URL}"

# Usar curl com a opção -k para ignorar verificação de certificado
AUTH_RESPONSE=$(curl -k -s -X POST "${PORTAINER_URL}/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')

log_message "Código HTTP retornado: ${HTTP_CODE}"

if [ "$HTTP_CODE" -ne 200 ]; then
    log_error "Erro na autenticação. Resposta completa: $AUTH_RESPONSE"
    
    # Tentar alternativa com HTTP em vez de HTTPS
    PORTAINER_URL_HTTP=$(echo "$PORTAINER_URL" | sed 's/https:/http:/')
    log_message "Tentando alternativa com HTTP: ${PORTAINER_URL_HTTP}/api/auth"
    
    AUTH_RESPONSE=$(curl -s -X POST "${PORTAINER_URL_HTTP}/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
        -w "\n%{http_code}")
    
    HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
    AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')
    
    log_message "Código HTTP alternativo: ${HTTP_CODE}"
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        error_exit "Autenticação falhou. Verifique a URL, usuário e senha do Portainer."
    else
        log_message "Conexão bem-sucedida usando HTTP. Continuando com HTTP..."
        PORTAINER_URL="$PORTAINER_URL_HTTP"
    fi
fi

JWT_TOKEN=$(echo "$AUTH_BODY" | grep -o '"jwt":"[^"]*' | cut -d'"' -f4)

if [ -z "$JWT_TOKEN" ]; then
    error_exit "Não foi possível extrair o token JWT da resposta: $AUTH_BODY"
fi

log_message "Autenticação bem-sucedida. Token JWT obtido."

# Listar endpoints disponíveis
log_message "Listando endpoints disponíveis..."
ENDPOINTS_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/endpoints" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$ENDPOINTS_RESPONSE" | tail -n1)
ENDPOINTS_BODY=$(echo "$ENDPOINTS_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
    error_exit "Falha ao listar endpoints. Código HTTP: ${HTTP_CODE}, Resposta: ${ENDPOINTS_BODY}"
fi

log_message "Endpoints disponíveis encontrados."
ENDPOINTS_LIST=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*,"Name":"[^"]*' | sed 's/"Id":\([0-9]*\),"Name":"\([^"]*\)"/ID: \1, Nome: \2/')
log_message "Lista de endpoints: $ENDPOINTS_LIST"

# Selecionar automaticamente o primeiro endpoint disponível
ENDPOINT_ID=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*' | head -1 | grep -o '[0-9]*')
    
if [ -z "$ENDPOINT_ID" ]; then
    error_exit "Não foi possível determinar o ID do endpoint."
else
    log_message "Usando o primeiro endpoint disponível (ID: ${ENDPOINT_ID})"
fi

# Verificar se o endpoint está em Swarm mode
log_message "Verificando se o endpoint está em modo Swarm..."
SWARM_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/endpoints/${ENDPOINT_ID}/docker/swarm" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$SWARM_RESPONSE" | tail -n1)
SWARM_BODY=$(echo "$SWARM_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
    error_exit "Falha ao obter informações do Swarm. Código HTTP: ${HTTP_CODE}, Resposta: ${SWARM_BODY}"
fi

SWARM_ID=$(echo "$SWARM_BODY" | grep -o '"ID":"[^"]*' | cut -d'"' -f4)

if [ -z "$SWARM_ID" ]; then
    error_exit "Não foi possível extrair o ID do Swarm. O endpoint selecionado está em modo Swarm?"
fi

log_message "ID do Swarm: ${SWARM_ID}"

# Função para processar a criação ou atualização de uma stack
process_stack() {
    local stack_name=$1
    local yaml_file="${stack_name}.yaml"
    
    log_message "Processando stack: ${stack_name}"
    
    # Verificar se a stack já existe
    STACK_LIST_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/stacks" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -w "\n%{http_code}")

    HTTP_CODE=$(echo "$STACK_LIST_RESPONSE" | tail -n1)
    STACK_LIST_BODY=$(echo "$STACK_LIST_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        log_error "Não foi possível verificar stacks existentes. Código HTTP: ${HTTP_CODE}"
        log_message "Continuando mesmo assim..."
    else
        # Verificar se uma stack com o mesmo nome já existe
        EXISTING_STACK_ID=$(echo "$STACK_LIST_BODY" | grep -o "\"Id\":[0-9]*,\"Name\":\"${stack_name}\"" | grep -o '"Id":[0-9]*' | grep -o '[0-9]*')
        
        if [ ! -z "$EXISTING_STACK_ID" ]; then
            log_message "Uma stack com o nome '${stack_name}' já existe (ID: ${EXISTING_STACK_ID})"
            log_message "Removendo a stack existente para recriá-la..."
            
            # Remover a stack existente
            DELETE_RESPONSE=$(curl -k -s -X DELETE "${PORTAINER_URL}/api/stacks/${EXISTING_STACK_ID}?endpointId=${ENDPOINT_ID}" \
                -H "Authorization: Bearer ${JWT_TOKEN}" \
                -w "\n%{http_code}")
            
            HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -n1)
            DELETE_BODY=$(echo "$DELETE_RESPONSE" | sed '$d')
            
            if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 204 ]; then
                log_error "Não foi possível remover a stack existente. Código HTTP: ${HTTP_CODE}"
                log_message "Continuando mesmo assim..."
            else
                log_message "Stack existente removida com sucesso."
            fi
            
            # Aguardar um momento para garantir que a stack foi removida
            sleep 3
        fi
    fi

    # Para depuração - mostrar o conteúdo do arquivo YAML
    log_message "Conteúdo do arquivo ${yaml_file} criado."

    # Criar arquivo temporário para capturar a saída de erro e a resposta
    erro_output=$(mktemp)
    response_output=$(mktemp)

    # Enviar a stack usando o endpoint multipart do Portainer
    log_message "Enviando a stack ${stack_name} para o Portainer..."
    http_code=$(curl -s -o "$response_output" -w "%{http_code}" -k -X POST \
      -H "Authorization: Bearer ${JWT_TOKEN}" \
      -F "Name=${stack_name}" \
      -F "file=@$(pwd)/${yaml_file}" \
      -F "SwarmID=${SWARM_ID}" \
      -F "endpointId=${ENDPOINT_ID}" \
      "${PORTAINER_URL}/api/stacks/create/swarm/file" 2> "$erro_output")

    response_body=$(cat "$response_output")

    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        # Verifica o conteúdo da resposta para garantir que o deploy foi bem-sucedido
        if echo "$response_body" | grep -q "\"Id\""; then
            log_message "Deploy da stack ${stack_name} feito com sucesso!"
            rm -f "$erro_output" "$response_output"
            return 0
        else
            log_error "Resposta inesperada do servidor ao tentar efetuar deploy da stack ${stack_name}."
            log_error "Resposta do servidor: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
        fi
    else
        log_error "Erro ao efetuar deploy. Resposta HTTP: ${http_code}"
        log_error "Mensagem de erro: $(cat "$erro_output")"
        log_error "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
        
        # Tentar método alternativo se falhar
        log_message "Tentando método alternativo de deploy..."
        # Tenta com outro endpoint do Portainer (método 2)
        http_code=$(curl -s -o "$response_output" -w "%{http_code}" -k -X POST \
          -H "Authorization: Bearer ${JWT_TOKEN}" \
          -H "Content-Type: multipart/form-data" \
          -F "Name=${stack_name}" \
          -F "file=@$(pwd)/${yaml_file}" \
          -F "SwarmID=${SWARM_ID}" \
          -F "endpointId=${ENDPOINT_ID}" \
          "${PORTAINER_URL}/api/stacks/create/file?endpointId=${ENDPOINT_ID}&type=1" 2> "$erro_output")
        
        response_body=$(cat "$response_output")
        
        if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
            log_message "Deploy da stack ${stack_name} feito com sucesso (método alternativo)!"
            rm -f "$erro_output" "$response_output"
            return 0
        else
            log_error "Erro ao efetuar deploy pelo método alternativo. Resposta HTTP: ${http_code}"
            log_error "Mensagem de erro: $(cat "$erro_output")"
            log_error "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
            
            # Último recurso - usar o Docker diretamente
            log_message "Tentando deploy direto via Docker Swarm..."
            if docker stack deploy --prune --resolve-image always -c "${yaml_file}" "${stack_name}"; then
                log_message "Deploy da stack ${stack_name} feito com sucesso via Docker Swarm!"
                log_message "Nota: A stack pode não ser editável no Portainer."
                rm -f "$erro_output" "$response_output"
                return 0
            else
                log_error "Falha em todos os métodos de deploy da stack ${stack_name}."
                rm -f "$erro_output" "$response_output"
                return 1
            fi
        fi
    fi

    # Remove os arquivos temporários
    rm -f "$erro_output" "$response_output"
}

# Implementar stacks na ordem correta: primeiro Redis e PostgreSQL, depois n8n
log_message "Iniciando deploy das stacks em sequência..."

# Processar Redis primeiro
log_message "Iniciando deploy da stack Redis..."
process_stack "$REDIS_STACK_NAME"
if [ $? -ne 0 ]; then
    log_error "Problemas ao implementar Redis, mas continuando..."
fi

# Processar PostgreSQL segundo
log_message "Iniciando deploy da stack PostgreSQL..."
process_stack "$PG_STACK_NAME"
if [ $? -ne 0 ]; then
    log_error "Problemas ao implementar PostgreSQL, mas continuando..."
fi

# Adicionar uma pausa para garantir que os serviços anteriores sejam inicializados
log_message "Aguardando 15 segundos para inicialização dos serviços Redis e PostgreSQL..."
sleep 15

# Processar n8n por último (depende dos outros)
log_message "Iniciando deploy da stack n8n..."
process_stack "$N8N_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack n8n."
fi

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    # Cria o arquivo de credenciais separadamente para evitar problemas com a saída
    cat > "${CREDENTIALS_DIR}/n8n${SUFFIX}.txt" << EOF
n8n Information
Editor URL: https://${N8N_EDITOR_DOMAIN}
Webhook URL: https://${N8N_WEBHOOK_DOMAIN}
Senha sugerida: ${N8N_SUGGESTED_PASSWORD}
Encryption Key: ${N8N_ENCRYPTION_KEY}
Postgres Password: ${POSTGRES_PASSWORD}
Database: postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/n8n_queue${SUFFIX}
EOF
    chmod 600 "${CREDENTIALS_DIR}/n8n${SUFFIX}.txt"
    log_message "Credenciais do n8n salvas em ${CREDENTIALS_DIR}/n8n${SUFFIX}.txt"
else
    log_error "Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console."
fi

# Criar um objeto JSON de saída para integração com outros sistemas
cat << EOF > /tmp/n8n${SUFFIX}_output.json
{
  "editorUrl": "https://${N8N_EDITOR_DOMAIN}",
  "webhookUrl": "https://${N8N_WEBHOOK_DOMAIN}",
  "encryptionKey": "${N8N_ENCRYPTION_KEY}",
  "postgresPassword": "${POSTGRES_PASSWORD}",
  "n8nStackName": "${N8N_STACK_NAME}",
  "redisStackName": "${REDIS_STACK_NAME}",
  "postgresStackName": "${PG_STACK_NAME}",
  "databaseUri": "postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/n8n_queue${SUFFIX}"
}
EOF

log_message "Arquivo JSON de saída criado em /tmp/n8n${SUFFIX}_output.json"

# Enviar webhook com logs de sucesso
send_webhook_with_logs "success" "Instalação do n8n concluída com sucesso"

echo "---------------------------------------------"
echo -e "${VERDE}[ n8n - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}Editor URL:${RESET} https://${N8N_EDITOR_DOMAIN}"
echo -e "${VERDE}Webhook URL:${RESET} https://${N8N_WEBHOOK_DOMAIN}"
echo -e "${VERDE}Senha sugerida:${RESET} ${N8N_SUGGESTED_PASSWORD}"
echo -e "${VERDE}Encryption Key:${RESET} ${N8N_ENCRYPTION_KEY}"
echo -e "${VERDE}Stacks criadas com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${REDIS_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${PG_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${N8N_STACK_NAME}${RESET}"
echo -e "${VERDE}Acesse seu n8n através do endereço:${RESET} https://${N8N_EDITOR_DOMAIN}"
echo -e "${VERDE}As stacks estão disponíveis e editáveis no Portainer.${RESET}"

log_message "Instalação concluída com sucesso!"
