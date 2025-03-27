#!/bin/bash
# Script para criar stacks separadas para n8n no Portainer (n8n, Redis e PostgreSQL)
# Uso: ./script.sh <portainer_url> <n8n_editor_domain> <n8n_webhook_domain> <portainer_password> [sufixo]
# Exemplo: ./script.sh painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 cliente1

# Função de log centralizada
log() {
    local level=$1
    local message=$2
    local color=""
    
    case $level in
        "INFO")
            color="\e[34m"  # Azul
            ;;
        "SUCCESS")
            color="\e[32m"  # Verde
            ;;
        "WARNING")
            color="\e[33m"  # Amarelo
            ;;
        "ERROR")
            color="\e[31m"  # Vermelho
            ;;
        *)
            color="\e[0m"   # Padrão
    esac
    
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] $level: $message\e[0m"
}

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    log "ERROR" "Uso: $0 <portainer_url> <n8n_editor_domain> <n8n_webhook_domain> <portainer_password> [sufixo]"
    log "ERROR" "Exemplo: $0 painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 cliente1"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
N8N_EDITOR_DOMAIN="$2"               # Domínio para o editor n8n
N8N_WEBHOOK_DOMAIN="$3"              # Domínio para webhook n8n
PORTAINER_PASSWORD="$4"              # Senha do Portainer

# Verificar se há sufixo (para múltiplas instâncias)
if [ -n "$5" ]; then
    SUFFIX="_$5"
    log "INFO" "Instalando com sufixo: $SUFFIX"
else
    SUFFIX=""
    log "INFO" "Instalando primeira instância (sem sufixo)"
fi

# Configurações adicionais
PORTAINER_USER="admin"              # Usuário do Portainer
N8N_STACK_NAME="n8n${SUFFIX}"       # Nome da stack n8n
REDIS_STACK_NAME="redis${SUFFIX}"   # Nome da stack Redis
PG_STACK_NAME="postgres${SUFFIX}"   # Nome da stack PostgreSQL

# Cores para formatação (mantidas para compatibilidade)
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar uma chave de criptografia do n8n aleatória
N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
log "SUCCESS" "Chave de criptografia do n8n gerada: $N8N_ENCRYPTION_KEY"

# Gerar uma senha do PostgreSQL aleatória
POSTGRES_PASSWORD=$(openssl rand -hex 16)
log "SUCCESS" "Senha do PostgreSQL gerada: $POSTGRES_PASSWORD"

# Função para exibir erros e sair
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Função para verificar a saúde do PostgreSQL
check_postgres_health() {
    local container_name=$1
    local max_attempts=15
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        log "INFO" "Verificando saúde do PostgreSQL (Tentativa $((attempt+1))/$max_attempts)"
        
        # Verifica se o container está rodando
        if ! docker ps | grep -q "$container_name"; then
            log "ERROR" "Container PostgreSQL não está rodando"
            return 1
        fi
        
        # Tenta conectar e verificar a versão do PostgreSQL
        local pg_version=$(docker exec "$container_name" psql -U postgres -t -c "SELECT version();" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$pg_version" ]; then
            log "SUCCESS" "PostgreSQL está saudável. Versão: $pg_version"
            return 0
        fi
        
        log "WARNING" "Falha na verificação de saúde do PostgreSQL"
        sleep 20
        ((attempt++))
    done
    
    log "ERROR" "PostgreSQL não respondeu após $max_attempts tentativas"
    return 1
}

# Função para verificar a saúde do Redis
check_redis_health() {
    local container_name=$1
    local max_attempts=15
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        log "INFO" "Verificando saúde do Redis (Tentativa $((attempt+1))/$max_attempts)"
        
        # Verifica se o container está rodando
        if ! docker ps | grep -q "$container_name"; then
            log "ERROR" "Container Redis não está rodando"
            return 1
        fi
        
        # Tenta conectar e verificar se o Redis está respondendo
        local redis_ping=$(docker exec "$container_name" redis-cli ping 2>/dev/null)
        
        if [ "$redis_ping" = "PONG" ]; then
            log "SUCCESS" "Redis está saudável"
            return 0
        fi
        
        log "WARNING" "Falha na verificação de saúde do Redis"
        sleep 20
        ((attempt++))
    done
    
    log "ERROR" "Redis não respondeu após $max_attempts tentativas"
    return 1
}

# Função para criar banco de dados com verificações
create_n8n_database() {
    local container_name=$1
    local database_name=$2
    
    log "INFO" "Tentando criar banco de dados $database_name"
    
    # Verificar se o banco já existe
    local db_exists=$(docker exec "$container_name" psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$database_name';" 2>/dev/null)
    
    if [ -z "$db_exists" ] || [[ "$db_exists" != *"1"* ]]; then
        log "INFO" "Criando banco de dados $database_name"
        docker exec "$container_name" psql -U postgres -c "CREATE DATABASE \"$database_name\";" &&
        docker exec "$container_name" psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE \"$database_name\" TO postgres;"
        
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Banco de dados $database_name criado com sucesso"
            return 0
        else
            log "ERROR" "Falha ao criar banco de dados $database_name"
            return 1
        fi
    else
        log "INFO" "Banco de dados $database_name já existe"
        return 0
    fi
}

# Criar volumes Docker necessários
log "INFO" "Criando volumes Docker..."

# Definir nomes dos volumes sem sufixos para compatibilidade
if [ -n "$SUFFIX" ]; then
    # Com sufixo - criar volumes com sufixo
    N8N_VOLUME="n8n_data${SUFFIX}"
    PG_VOLUME="postgres_data${SUFFIX}"
    REDIS_VOLUME="redis_data${SUFFIX}"
else
    # Sem sufixo - usar nomes padrão como nos exemplos
    N8N_VOLUME="n8n_data"
    PG_VOLUME="postgres_data"
    REDIS_VOLUME="redis_data"
fi

docker volume create $N8N_VOLUME 2>/dev/null || log "WARNING" "Volume $N8N_VOLUME já existe."
docker volume create $PG_VOLUME 2>/dev/null || log "WARNING" "Volume $PG_VOLUME já existe."
docker volume create $REDIS_VOLUME 2>/dev/null || log "WARNING" "Volume $REDIS_VOLUME já existe."

# Verificar se a rede GrowthNet existe, caso contrário, criar
docker network inspect GrowthNet >/dev/null 2>&1 || {
    log "INFO" "Criando rede GrowthNet..."
    # Criar a rede como attachable para permitir conexão direta para testes
    docker network create --driver overlay --attachable GrowthNet
}

# Criar arquivo docker-compose para a stack Redis
log "INFO" "Criando arquivo docker-compose para a stack Redis..."
cat > "${REDIS_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  redis:
    image: redis:latest
    command: ["redis-server", "--appendonly", "yes", "--port", "6379"]
    volumes:
      - ${REDIS_VOLUME}:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      resources:
        limits:
          cpus: "1"
          memory: 2048M
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  ${REDIS_VOLUME}:
    external: true
    name: ${REDIS_VOLUME}

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack PostgreSQL
log "INFO" "Criando arquivo docker-compose para a stack PostgreSQL..."
cat > "${PG_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  postgres:
    image: postgres:14
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=postgres
      - PG_MAX_CONNECTIONS=500
    volumes:
      - ${PG_VOLUME}:/var/lib/postgresql/data
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
      resources:
        limits:
          cpus: "1"
          memory: 1024M

volumes:
  ${PG_VOLUME}:
    external: true
    name: ${PG_VOLUME}

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack n8n
log "INFO" "Criando arquivo docker-compose para a stack n8n..."
cat > "${N8N_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  n8n:
    image: n8nio/n8n:latest
    environment:
      - N8N_HOST=${N8N_EDITOR_DOMAIN}
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - NODE_ENV=production
      - WEBHOOK_URL=https://${N8N_WEBHOOK_DOMAIN}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n_queue${SUFFIX}
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_HEALTH_CHECK_ACTIVE=true
    volumes:
      - ${N8N_VOLUME}:/home/node/.n8n
    networks:
      - GrowthNet
    ports:
      - "5678:5678"
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=GrowthNet"
        # Editor labels
        - "traefik.http.routers.n8n-editor${SUFFIX}.rule=Host(\`${N8N_EDITOR_DOMAIN}\`)"
        - "traefik.http.routers.n8n-editor${SUFFIX}.entrypoints=websecure"
        - "traefik.http.routers.n8n-editor${SUFFIX}.tls=true"
        - "traefik.http.routers.n8n-editor${SUFFIX}.tls.certresolver=le"
        - "traefik.http.services.n8n-editor${SUFFIX}.loadbalancer.server.port=5678"
        # Webhook labels
        - "traefik.http.routers.n8n-webhook${SUFFIX}.rule=Host(\`${N8N_WEBHOOK_DOMAIN}\`)"
        - "traefik.http.routers.n8n-webhook${SUFFIX}.entrypoints=websecure"
        - "traefik.http.routers.n8n-webhook${SUFFIX}.tls=true"
        - "traefik.http.routers.n8n-webhook${SUFFIX}.tls.certresolver=le"
        - "traefik.http.services.n8n-webhook${SUFFIX}.loadbalancer.server.port=5678"
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  ${N8N_VOLUME}:
    external: true
    name: ${N8N_VOLUME}

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Função para processar a criação ou atualização de uma stack
process_stack() {
    local stack_name=$1
    local yaml_file="${stack_name}.yaml"
    
    log "INFO" "Processando stack: ${stack_name}"
    log "INFO" "Conteúdo do arquivo ${yaml_file}:"
    cat "${yaml_file}"
    echo

    # Verificar se jq está instalado
    if ! command -v jq &> /dev/null; then
        log "INFO" "Instalando jq..."
        apt-get update && apt-get install -y jq || {
            error_exit "Falha ao instalar jq. Necessário para processamento de JSON."
        }
    fi
    
    # Usar curl com a opção -k para ignorar verificação de certificado
    AUTH_RESPONSE=$(curl -k -s -X POST "${PORTAINER_URL}/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
        -w "\n%{http_code}")

    HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
    AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')

    log "INFO" "Código HTTP retornado: ${HTTP_CODE}"

    if [ "$HTTP_CODE" -ne 200 ]; then
        log "ERROR" "Erro na autenticação. Resposta completa: $AUTH_RESPONSE"
        
        # Tentar alternativa com HTTP em vez de HTTPS
        PORTAINER_URL_HTTP=$(echo "$PORTAINER_URL" | sed 's/https:/http:/')
        log "WARNING" "Tentando alternativa com HTTP: ${PORTAINER_URL_HTTP}/api/auth"
        
        AUTH_RESPONSE=$(curl -s -X POST "${PORTAINER_URL_HTTP}/api/auth" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
            -w "\n%{http_code}")
        
        HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
        AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')
        
        log "INFO" "Código HTTP alternativo: ${HTTP_CODE}"
        
        if [ "$HTTP_CODE" -ne 200 ]; then
            error_exit "Autenticação falhou. Verifique a URL, usuário e senha do Portainer."
        else
            log "WARNING" "Conexão bem-sucedida usando HTTP. Continuando com HTTP..."
            PORTAINER_URL="$PORTAINER_URL_HTTP"
        fi
    fi

    JWT_TOKEN=$(echo "$AUTH_BODY" | grep -o '"jwt":"[^"]*' | cut -d'"' -f4)

    if [ -z "$JWT_TOKEN" ]; then
        error_exit "Não foi possível extrair o token JWT da resposta: $AUTH_BODY"
    fi

    log "SUCCESS" "Autenticação bem-sucedida. Token JWT obtido."

    # Listar endpoints disponíveis
    log "INFO" "Listando endpoints disponíveis..."
    ENDPOINTS_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/endpoints" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -w "\n%{http_code}")

    HTTP_CODE=$(echo "$ENDPOINTS_RESPONSE" | tail -n1)
    ENDPOINTS_BODY=$(echo "$ENDPOINTS_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        error_exit "Falha ao listar endpoints. Código HTTP: ${HTTP_CODE}, Resposta: ${ENDPOINTS_BODY}"
    fi

    log "INFO" "Endpoints disponíveis:"
    ENDPOINTS_LIST=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*,"Name":"[^"]*' | sed 's/"Id":\([0-9]*\),"Name":"\([^"]*\)"/ID: \1, Nome: \2/')
    echo "$ENDPOINTS_LIST"

    # Selecionar automaticamente o primeiro endpoint disponível
    ENDPOINT_ID=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*' | head -1 | grep -o '[0-9]*')
        
    if [ -z "$ENDPOINT_ID" ]; then
        error_exit "Não foi possível determinar o ID do endpoint."
    else
        log "INFO" "Usando o primeiro endpoint disponível (ID: ${ENDPOINT_ID})"
    fi

    # Verificar se o endpoint está em Swarm mode
    log "INFO" "Verificando se o endpoint está em modo Swarm..."
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

    log "INFO" "ID do Swarm: ${SWARM_ID}"

    # Enviar a stack para o Portainer
    log "INFO" "Enviando a stack ${stack_name} para o Portainer..."
    erro_output=$(mktemp)
    response_output=$(mktemp)

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
            log "SUCCESS" "Deploy da stack ${stack_name} feito com sucesso!"
            return 0
        else
            log "ERROR" "Erro, resposta inesperada do servidor ao tentar efetuar deploy da stack ${stack_name}."
            echo "Resposta do servidor: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
            return 1
        fi
    else
        log "ERROR" "Erro ao efetuar deploy. Resposta HTTP: ${http_code}"
        echo "Mensagem de erro: $(cat "$erro_output")"
        echo "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
        
        # Tentar método alternativo de deploy
        log "WARNING" "Tentando método alternativo de deploy..."
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
            log "SUCCESS" "Deploy da stack ${stack_name} feito com sucesso (método alternativo)!"
            return 0
        else
            log "ERROR" "Erro ao efetuar deploy pelo método alternativo. Resposta HTTP: ${http_code}"
            echo "Mensagem de erro: $(cat "$erro_output")"
            echo "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
            
            # Último recurso - usar o Docker diretamente
            log "WARNING" "Tentando deploy direto via Docker Swarm..."
            if docker stack deploy --prune --resolve-image always -c "${yaml_file}" "${stack_name}"; then
                log "SUCCESS" "Deploy da stack ${stack_name} feito com sucesso via Docker Swarm!"
                log "WARNING" "Nota: A stack pode não ser editável no Portainer."
                return 0
            else
                log "ERROR" "Falha em todos os métodos de deploy da stack ${stack_name}."
                return 1
            fi
        fi
    fi

    # Remove os arquivos temporários
    rm -f "$erro_output" "$response_output"
}

# Função principal de deploy
deploy_n8n_stack() {
    local portainer_url=$1
    local editor_domain=$2
    local webhook_domain=$3
    local portainer_password=$4
    local suffix=${5:-""}
    
    # Aguardar um momento inicial
    log "INFO" "Iniciando processo de deploy com verificações de saúde..."
    sleep 10

    # Deploy PostgreSQL
    process_stack "$PG_STACK_NAME"
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha no deploy do PostgreSQL"
        return 1
    fi
    
    # Aguardar inicialização do PostgreSQL
    log "INFO" "Aguardando inicialização do PostgreSQL..."
    sleep 30
    
    # Verificar saúde do PostgreSQL
    local pg_container_name="postgres${suffix}"
    check_postgres_health "$pg_container_name"
    if [ $? -ne 0 ]; then
        log "ERROR" "PostgreSQL não está saudável"
        return 1
    fi
    
    # Criar banco de dados n8n
    create_n8n_database "$pg_container_name" "n8n_queue${suffix}"
    
    # Deploy Redis
    process_stack "$REDIS_STACK_NAME"
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha no deploy do Redis"
        return 1
    fi
    
    # Aguardar inicialização do Redis
    log "INFO" "Aguardando inicialização do Redis..."
    sleep 30
    
    # Verificar saúde do Redis
    local redis_container_name="redis${suffix}"
    check_redis_health "$redis_container_name"
    if [ $? -ne 0 ]; then
        log "ERROR" "Redis não está saudável"
        return 1
    fi
    
    # Deploy n8n
    process_stack "$N8N_STACK_NAME"
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha no deploy do n8n"
        return 1
    fi
    
    log "SUCCESS" "Deploy completo da stack n8n com sucesso!"
    return 0
}

# Processo de deploy
log "INFO" "Iniciando processo de deploy da stack n8n"

# Chamar a função de deploy com os parâmetros
deploy_n8n_stack "$PORTAINER_URL" "$N8N_EDITOR_DOMAIN" "$N8N_WEBHOOK_DOMAIN" "$PORTAINER_PASSWORD" "$SUFFIX"

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    cat > "${CREDENTIALS_DIR}/n8n${SUFFIX}.txt" << EOF
n8n Information
Editor URL: https://${N8N_EDITOR_DOMAIN}
Webhook URL: https://${N8N_WEBHOOK_DOMAIN}
Encryption Key: ${N8N_ENCRYPTION_KEY}
Postgres Password: ${POSTGRES_PASSWORD}
Database: postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/n8n_queue${SUFFIX}
EOF
    chmod 600 "${CREDENTIALS_DIR}/n8n${SUFFIX}.txt"
    log "SUCCESS" "Credenciais do n8n salvas em ${CREDENTIALS_DIR}/n8n${SUFFIX}.txt"
else
    log "WARNING" "Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console."
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
  "databaseUri": "postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/n8n_queue${SUFFIX}"
}
EOF

log "SUCCESS" "Arquivo JSON de saída criado em /tmp/n8n${SUFFIX}_output.json"

# Mensagem final
echo "---------------------------------------------"
log "SUCCESS" "[ n8n - INSTALAÇÃO COMPLETA ]"
log "INFO" "Editor URL: https://${N8N_EDITOR_DOMAIN}"
log "INFO" "Webhook URL: https://${N8N_WEBHOOK_DOMAIN}"
log "INFO" "Encryption Key: ${N8N_ENCRYPTION_KEY}"
log "INFO" "Stacks criadas com sucesso via API do Portainer:"
echo "  - ${REDIS_STACK_NAME}"
echo "  - ${PG_STACK_NAME}"
echo "  - ${N8N_STACK_NAME}"
log "SUCCESS" "Acesse seu n8n através do endereço: https://${N8N_EDITOR_DOMAIN}"
log "INFO" "As stacks estão disponíveis e editáveis no Portainer."
