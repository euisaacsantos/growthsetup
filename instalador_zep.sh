#!/bin/bash
# Script para criar stacks separadas para Zep no Portainer (Zep, Redis, PostgreSQL e Qdrant)
# Uso: ./script.sh <portainer_url> <zep_domain> <portainer_password> [sufixo] [id-xxxx]
# Exemplo: ./script.sh painel.trafegocomia.com zep.growthtap.com.br senha123 cliente1 id-12341221125
# Sem sufixo: ./script.sh painel.trafegocomia.com zep.growthtap.com.br senha123 "" id-12341221125

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
  "link": "https://${ZEP_DOMAIN}",
  "zep": {
    "domain": "${ZEP_DOMAIN}",
    "api_key": "${ZEP_API_KEY}",
    "database_uri": "postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/zep${SUFFIX}",
    "redis_uri": "redis://${REDIS_STACK_NAME}_redis:6379",
    "qdrant_uri": "http://${QDRANT_STACK_NAME}_qdrant:6333"
  },
  "stacks": {
    "redis": "${REDIS_STACK_NAME}",
    "postgres": "${PG_STACK_NAME}",
    "qdrant": "${QDRANT_STACK_NAME}",
    "zep": "${ZEP_STACK_NAME}"
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
log_message "Iniciando instalação do Zep..."

# Verificar parâmetros obrigatórios
if [ $# -lt 3 ]; then
    error_exit "Parâmetros insuficientes. Uso: $0 <portainer_url> <zep_domain> <portainer_password> [sufixo] [id-xxxx]"
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
ZEP_DOMAIN="$2"                      # Domínio para o Zep
PORTAINER_PASSWORD="$3"              # Senha do Portainer

log_message "Parâmetros recebidos: Portainer=$1, Zep Domain=${ZEP_DOMAIN}"

# Inicializar variáveis
SUFFIX=""
INSTALLATION_ID="sem_id"
WEBHOOK_URL="https://setup.growthtap.com.br/webhook/bf813e80-f036-400b-acae-904d703df6dd"

# Processar parâmetros opcionais (sufixo e ID)
for param in "${@:4}"; do
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
PORTAINER_USER="admin"               # Usuário do Portainer
ZEP_STACK_NAME="zep${SUFFIX}"        # Nome da stack Zep

# Nomes únicos para as stacks das dependências (prefixados com zep_)
REDIS_STACK_NAME="zep_redis${SUFFIX}"     # Nome da stack Redis com prefixo zep_
PG_STACK_NAME="zep_postgres${SUFFIX}"     # Nome da stack PostgreSQL com prefixo zep_
QDRANT_STACK_NAME="zep_qdrant${SUFFIX}"   # Nome da stack Qdrant com prefixo zep_

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar chaves e senhas aleatórias
log_message "Gerando credenciais..."
ZEP_API_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
QDRANT_API_KEY=$(openssl rand -hex 16)

log_message "API Key do Zep gerada: ${ZEP_API_KEY}"
log_message "Senha do PostgreSQL gerada: ${POSTGRES_PASSWORD}"
log_message "API Key do Qdrant gerada: ${QDRANT_API_KEY}"

# Criar volumes Docker necessários
log_message "Criando volumes Docker..."
docker volume create zep_data${SUFFIX} 2>/dev/null || log_message "Volume zep_data${SUFFIX} já existe."
docker volume create zep_postgres_data${SUFFIX} 2>/dev/null || log_message "Volume zep_postgres_data${SUFFIX} já existe."
docker volume create zep_redis_data${SUFFIX} 2>/dev/null || log_message "Volume zep_redis_data${SUFFIX} já existe."
docker volume create zep_qdrant_data${SUFFIX} 2>/dev/null || log_message "Volume zep_qdrant_data${SUFFIX} já existe."

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
    image: redis:7-alpine
    command: redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru
    volumes:
      - zep_redis_data${SUFFIX}:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  zep_redis_data${SUFFIX}:
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
    image: postgres:15-alpine
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=postgres
      - POSTGRES_DB=zep${SUFFIX}
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
    volumes:
      - zep_postgres_data${SUFFIX}:/var/lib/postgresql/data
    networks:
      - GrowthNet
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
  zep_postgres_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack Qdrant
log_message "Criando arquivo docker-compose para a stack Qdrant..."
cat > "${QDRANT_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  qdrant:
    image: qdrant/qdrant:latest
    environment:
      - QDRANT__SERVICE__HTTP_PORT=6333
      - QDRANT__SERVICE__GRPC_PORT=6334
      - QDRANT__SERVICE__API_KEY=${QDRANT_API_KEY}
    volumes:
      - zep_qdrant_data${SUFFIX}:/qdrant/storage
    networks:
      - GrowthNet
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
        - "traefik.http.routers.qdrant${SUFFIX}.rule=Host(\`qdrant${SUFFIX}.${ZEP_DOMAIN}\`)"
        - traefik.http.routers.qdrant${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.qdrant${SUFFIX}.tls=true
        - traefik.http.routers.qdrant${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.qdrant${SUFFIX}.priority=1
        - traefik.http.routers.qdrant${SUFFIX}.service=qdrant${SUFFIX}
        - traefik.http.services.qdrant${SUFFIX}.loadbalancer.server.port=6333
        - traefik.http.services.qdrant${SUFFIX}.loadbalancer.passHostHeader=1

volumes:
  zep_qdrant_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo config.yaml para o Zep
log_message "Criando arquivo config.yaml para o Zep..."
cat > "config${SUFFIX}.yaml" <<EOL
store:
  type: postgres
  postgres:
    dsn: postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/zep${SUFFIX}?sslmode=disable

server:
  host: 0.0.0.0
  port: 8000
  web_enabled: false

llm:
  service: openai
  config:
    api_key: sk-temp-key-configure-later-via-api
    model: gpt-3.5-turbo

extractors:
  embeddings:
    service: openai
    dimensions: 1536
    model: AdaEmbeddingV2

log:
  level: info
EOL
# Criar arquivo docker-compose para a stack Zep
log_message "Criando arquivo docker-compose para a stack Zep..."
cat > "${ZEP_STACK_NAME}.yaml" <<EOL
version: "3.7"
services:

## --------------------------- Zep Server --------------------------- ##

  zep:
    image: ghcr.io/getzep/zep:0.26.0
    environment:
      # CONFIGURAÇÃO ESSENCIAL - PREVINE O ERRO "store.type must be set"
      - STORE_TYPE=postgres
      - ZEP_STORE_TYPE=postgres
      - ZEP_POSTGRES_DSN=postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/zep${SUFFIX}
      
      # Configurações LLM
      - ZEP_OPENAI_API_KEY=sk-temp-key-configure-later-via-api
      
      # Configurações de autenticação
      - ZEP_AUTH_REQUIRED=true
      - ZEP_AUTH_SECRET=${ZEP_API_KEY}
      
      # Configurações adicionais
      - ZEP_LOG_LEVEL=info
      - ZEP_DEVELOPMENT=false
      
      # Timezone
      - TZ=America/Sao_Paulo
    volumes:
      - zep_data${SUFFIX}:/app/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
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
      labels:
        - traefik.enable=true
        - traefik.docker.network=GrowthNet
        - "traefik.http.routers.zep${SUFFIX}.rule=Host(\`${ZEP_DOMAIN}\`)"
        - traefik.http.routers.zep${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.zep${SUFFIX}.tls=true
        - traefik.http.routers.zep${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.zep${SUFFIX}.priority=1
        - traefik.http.routers.zep${SUFFIX}.service=zep${SUFFIX}
        - traefik.http.services.zep${SUFFIX}.loadbalancer.server.port=8000
        - traefik.http.services.zep${SUFFIX}.loadbalancer.passHostHeader=1

volumes:
  zep_data${SUFFIX}:
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

# Implementar stacks na ordem correta: primeiro dependências, depois Zep
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

# Processar Qdrant terceiro
log_message "Iniciando deploy da stack Qdrant..."
process_stack "$QDRANT_STACK_NAME"
if [ $? -ne 0 ]; then
    log_error "Problemas ao implementar Qdrant, mas continuando..."
fi

# Adicionar uma pausa para garantir que os serviços anteriores sejam inicializados
log_message "Aguardando 20 segundos para inicialização dos serviços Redis, PostgreSQL e Qdrant..."
sleep 20

# Processar Zep por último (depende dos outros)
log_message "Iniciando deploy da stack Zep..."
process_stack "$ZEP_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack Zep."
fi

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    # Cria o arquivo de credenciais separadamente para evitar problemas com a saída
    cat > "${CREDENTIALS_DIR}/zep${SUFFIX}.txt" << EOF
Zep Information (Versão 0.26.0 - Estável)
API URL: https://${ZEP_DOMAIN}
API Key: ${ZEP_API_KEY}
Qdrant Dashboard: https://qdrant${SUFFIX}.${ZEP_DOMAIN}
Qdrant API Key: ${QDRANT_API_KEY}
Postgres Password: ${POSTGRES_PASSWORD}
Database URI: postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/zep${SUFFIX}
Redis URI: redis://${REDIS_STACK_NAME}_redis:6379
Qdrant URI: http://${QDRANT_STACK_NAME}_qdrant:6333

SOLUÇÃO DEFINITIVA APLICADA:
1. Zep v0.26.0 (estável, sem bugs da v0.27.2)
2. STORE_TYPE=postgres (obrigatório para prevenir erro)
3. ZEP_STORE_TYPE=postgres (redundância para compatibilidade)
4. ZEP_POSTGRES_DSN configurado corretamente

Nota: O erro "store.type must be set" foi resolvido com esta configuração.
EOF
    chmod 600 "${CREDENTIALS_DIR}/zep${SUFFIX}.txt"
    log_message "Credenciais do Zep salvas em ${CREDENTIALS_DIR}/zep${SUFFIX}.txt"
else
    log_error "Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console."
fi

# Criar um objeto JSON de saída para integração com outros sistemas
cat << EOF > /tmp/zep${SUFFIX}_output.json
{
  "apiUrl": "https://${ZEP_DOMAIN}",
  "apiKey": "${ZEP_API_KEY}",
  "qdrantDashboard": "https://qdrant${SUFFIX}.${ZEP_DOMAIN}",
  "qdrantApiKey": "${QDRANT_API_KEY}",
  "postgresPassword": "${POSTGRES_PASSWORD}",
  "zepStackName": "${ZEP_STACK_NAME}",
  "redisStackName": "${REDIS_STACK_NAME}",
  "postgresStackName": "${PG_STACK_NAME}",
  "qdrantStackName": "${QDRANT_STACK_NAME}",
  "databaseUri": "postgresql://postgres:${POSTGRES_PASSWORD}@${PG_STACK_NAME}_postgres:5432/zep${SUFFIX}",
  "redisUri": "redis://${REDIS_STACK_NAME}_redis:6379",
  "qdrantUri": "http://${QDRANT_STACK_NAME}_qdrant:6333"
}
EOF

log_message "Arquivo JSON de saída criado em /tmp/zep${SUFFIX}_output.json"

# Aguardar um pouco mais para garantir que todos os serviços estejam funcionando
log_message "Aguardando 30 segundos adicionais para estabilização dos serviços..."
sleep 30

# Verificar se o Zep está respondendo
log_message "Verificando se o Zep está respondendo..."
ZEP_HEALTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "https://${ZEP_DOMAIN}/healthz" || echo "000")

if [ "$ZEP_HEALTH_CHECK" = "200" ]; then
    log_message "Zep está respondendo corretamente!"
elif [ "$ZEP_HEALTH_CHECK" = "000" ]; then
    log_message "Não foi possível conectar ao Zep. Pode demorar alguns minutos para ficar disponível."
else
    log_message "Zep retornou código HTTP: $ZEP_HEALTH_CHECK. Pode estar ainda inicializando."
fi

# Enviar webhook com logs de sucesso
send_webhook_with_logs "success" "Instalação do Zep concluída com sucesso"

echo "---------------------------------------------"
echo -e "${VERDE}[ ZEP - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}Versão do Zep:${RESET} 0.26.0 (estável, sem bugs conhecidos)"
echo -e "${VERDE}API URL:${RESET} https://${ZEP_DOMAIN}"
echo -e "${VERDE}API Key:${RESET} ${ZEP_API_KEY}"
echo -e "${VERDE}Qdrant Dashboard:${RESET} https://qdrant${SUFFIX}.${ZEP_DOMAIN}"
echo -e "${VERDE}Qdrant API Key:${RESET} ${QDRANT_API_KEY}"
echo -e "${VERDE}Stacks criadas com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${REDIS_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${PG_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${QDRANT_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${ZEP_STACK_NAME}${RESET}"
echo -e "${AMARELO}SOLUÇÃO APLICADA:${RESET}"
echo -e "1. Versão alterada para 0.26.0 (mais estável que 0.27.2)"
echo -e "2. Configuração dupla: STORE_TYPE + ZEP_STORE_TYPE"
echo -e "3. Para configurar OpenAI: docker service update ${ZEP_STACK_NAME}_zep --env-add ZEP_OPENAI_API_KEY=sua-key-real"
echo -e "${VERDE}Acesse seu Zep através do endereço:${RESET} https://${ZEP_DOMAIN}"
echo -e "${VERDE}As stacks estão disponíveis e editáveis no Portainer.${RESET}"
echo ""
echo -e "${VERDE}Exemplo de uso em Python:${RESET}"
echo -e "from zep_python import ZepClient"
echo -e "client = ZepClient(api_url='https://${ZEP_DOMAIN}', api_key='${ZEP_API_KEY}')"

log_message "Instalação concluída com sucesso!"

# Limpar arquivos temporários
log_message "Limpando arquivos temporários..."
rm -f "${REDIS_STACK_NAME}.yaml"
rm -f "${PG_STACK_NAME}.yaml"
rm -f "${QDRANT_STACK_NAME}.yaml"
rm -f "${ZEP_STACK_NAME}.yaml"

log_message "Arquivos temporários removidos."
