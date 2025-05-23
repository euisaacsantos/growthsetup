#!/bin/bash
# Script para criar stacks separadas no Portainer (Evolution, Redis e PostgreSQL)
# Uso: ./script.sh <portainer_url> <evolution_domain> <portainer_password> [sufixo] [id-xxxx]
# Exemplo: ./script.sh painel.trafegocomia.com api.trafegocomia.com senha123 cliente1 id-12341221125
# Ou sem sufixo: ./script.sh painel.trafegocomia.com api.trafegocomia.com senha123 "" id-12341221125

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
  "link": "https://${EVOLUTION_DOMAIN}",
  "password": "${API_KEY}",
  "evolution": {
    "domain": "${EVOLUTION_DOMAIN}",
    "api_key": "${API_KEY}",
    "manager_url": "https://${EVOLUTION_DOMAIN}/manager",
    "database_uri": "postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres${SUFFIX}:5432/evolution${SUFFIX}"
  },
  "stacks": {
    "redis": "${REDIS_STACK_NAME}",
    "postgres": "${PG_STACK_NAME}",
    "evolution": "${EVO_STACK_NAME}"
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
log_message "Iniciando instalação da Evolution API..."

# Verificar parâmetros obrigatórios
if [ $# -lt 3 ]; then
    error_exit "Parâmetros insuficientes. Uso: $0 <portainer_url> <evolution_domain> <portainer_password> [sufixo] [id-xxxx]"
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"        # URL do Portainer
EVOLUTION_DOMAIN="$2"             # Domínio para a Evolution API
PORTAINER_PASSWORD="$3"           # Senha do Portainer

log_message "Parâmetros recebidos: Portainer=$1, Evolution=${EVOLUTION_DOMAIN}"

# Inicializar variáveis
SUFFIX=""
INSTALLATION_ID="sem_id"

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
PORTAINER_USER="admin"              # Usuário do Portainer
EVO_STACK_NAME="evolution${SUFFIX}" # Nome da stack Evolution

# Nomes únicos para as stacks do Redis e PostgreSQL (prefixados com evolution_)
REDIS_STACK_NAME="evolution_redis${SUFFIX}"   # Nome da stack Redis com prefixo evolution_
PG_STACK_NAME="evolution_postgres${SUFFIX}"   # Nome da stack PostgreSQL com prefixo evolution_

WEBHOOK_URL="https://setup.growthtap.com.br/webhook/bf813e80-f036-400b-acae-904d703df6dd"

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Verificar se já existe uma API key no volume evolution_instances
log_message "Verificando se já existe uma API key..."
EXISTING_API_KEY=""

# Tenta extrair a API key existente de um container temporário
if docker volume inspect evolution_instances${SUFFIX} &>/dev/null; then
    log_message "Volume evolution_instances${SUFFIX} já existe. Tentando extrair a API key existente..."
    
    # Criar um container temporário para tentar encontrar a API key no volume
    # Isso é um exemplo - a API key pode estar armazenada em diferentes formatos/locais
    docker run --rm -v evolution_instances${SUFFIX}:/data alpine:latest sh -c "if [ -f /data/config.json ]; then grep -o '\"apiKey\":\"[^\"]*\"' /data/config.json | cut -d '\"' -f 4; fi" > /tmp/existing_api_key_output.txt
    
    EXISTING_API_KEY=$(cat /tmp/existing_api_key_output.txt)
    rm -f /tmp/existing_api_key_output.txt
    
    if [ -n "$EXISTING_API_KEY" ]; then
        log_message "API key existente encontrada. Usando-a em vez de gerar uma nova."
        API_KEY=$EXISTING_API_KEY
    else
        log_message "Não foi possível extrair a API key existente ou o arquivo de configuração não existe."
        log_message "Gerando uma nova API key..."
        API_KEY=$(openssl rand -hex 16)
    fi
else
    log_message "Volume evolution_instances${SUFFIX} não existe. Gerando uma nova API key..."
    API_KEY=$(openssl rand -hex 16)
fi

log_message "API key: ${API_KEY}"

# Criar volumes Docker necessários
log_message "Criando volumes Docker..."
docker volume create evolution_redis_data${SUFFIX} 2>/dev/null || log_message "Volume evolution_redis_data${SUFFIX} já existe."
docker volume create evolution_postgres_data${SUFFIX} 2>/dev/null || log_message "Volume evolution_postgres_data${SUFFIX} já existe."
docker volume create evolution_instances${SUFFIX} 2>/dev/null || log_message "Volume evolution_instances${SUFFIX} já existe."

# Criar rede overlay se não existir
if docker network create --driver overlay GrowthNet 2>/dev/null; then
    log_message "Rede GrowthNet criada com sucesso."
else
    log_message "Rede GrowthNet já existe."
fi

# Criar arquivo docker-compose para a stack Redis
log_message "Criando arquivo docker-compose para a stack Redis..."
cat > "${REDIS_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  redis${SUFFIX}:
    image: redis:latest
    command: redis-server --appendonly yes
    volumes:
      - evolution_redis_data${SUFFIX}:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

volumes:
  evolution_redis_data${SUFFIX}:
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
  postgres${SUFFIX}:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=b2ecbaa44551df03fa3793b38091cff7
      - POSTGRES_USER=postgres
    volumes:
      - evolution_postgres_data${SUFFIX}:/var/lib/postgresql/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

volumes:
  evolution_postgres_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack Evolution
log_message "Criando arquivo docker-compose para a stack Evolution..."
cat > "${EVO_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  evolution${SUFFIX}:
    image: atendai/evolution-api:latest
    volumes:
      - evolution_instances${SUFFIX}:/evolution/instances
    networks:
      - GrowthNet
    environment:
      - SERVER_URL=https://${EVOLUTION_DOMAIN}
      - AUTHENTICATION_API_KEY=${API_KEY}
      - AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
      - DEL_INSTANCE=false
      - QRCODE_LIMIT=1902
      - LANGUAGE=pt-BR
      - CONFIG_SESSION_PHONE_VERSION=2.3000.1019780779
      - CONFIG_SESSION_PHONE_CLIENT=GrowthTap
      - CONFIG_SESSION_PHONE_NAME=Chrome
      - DATABASE_ENABLED=true
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres${SUFFIX}:5432/evolution${SUFFIX}
      - DATABASE_CONNECTION_CLIENT_NAME=evolution${SUFFIX}
      - DATABASE_SAVE_DATA_INSTANCE=true
      - DATABASE_SAVE_DATA_NEW_MESSAGE=true
      - DATABASE_SAVE_MESSAGE_UPDATE=true
      - DATABASE_SAVE_DATA_CONTACTS=true
      - DATABASE_SAVE_DATA_CHATS=true
      - DATABASE_SAVE_DATA_LABELS=true
      - DATABASE_SAVE_DATA_HISTORIC=true
      - OPENAI_ENABLED=true
      - DIFY_ENABLED=true
      - TYPEBOT_ENABLED=true
      - TYPEBOT_API_VERSION=latest
      - CHATWOOT_ENABLED=true
      - CHATWOOT_MESSAGE_READ=true
      - CHATWOOT_MESSAGE_DELETE=true
      - CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres${SUFFIX}:5432/chatwoot?sslmode=disable
      - CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=false
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://redis${SUFFIX}:6379/8
      - CACHE_REDIS_PREFIX_KEY=evolution
      - CACHE_REDIS_SAVE_INSTANCES=false
      - CACHE_LOCAL_ENABLED=false
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      labels:
      - traefik.enable=true
      - traefik.http.routers.evolution${SUFFIX}.rule=Host(\`${EVOLUTION_DOMAIN}\`)
      - traefik.http.routers.evolution${SUFFIX}.entrypoints=websecure
      - traefik.http.routers.evolution${SUFFIX}.priority=1
      - traefik.http.routers.evolution${SUFFIX}.tls.certresolver=letsencryptresolver
      - traefik.http.routers.evolution${SUFFIX}.service=evolution${SUFFIX}
      - traefik.http.services.evolution${SUFFIX}.loadbalancer.server.port=8080
      - traefik.http.services.evolution${SUFFIX}.loadbalancer.passHostHeader=1

volumes:
  evolution_instances${SUFFIX}:
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

# Implementar stacks na ordem correta: primeiro Redis e PostgreSQL, depois Evolution
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

# Processar Evolution por último (depende dos outros)
# Adicionar uma pausa para garantir que os serviços anteriores sejam inicializados
log_message "Aguardando 10 segundos para inicialização dos serviços Redis e PostgreSQL..."
sleep 10

log_message "Iniciando deploy da stack Evolution..."
process_stack "$EVO_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack Evolution."
fi

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    cat > "${CREDENTIALS_DIR}/evolution${SUFFIX}.txt" << EOF
Evolution API Information
URL: https://${EVOLUTION_DOMAIN}
API Key: ${API_KEY}
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres${SUFFIX}:5432/evolution${SUFFIX}
EOF
    chmod 600 "${CREDENTIALS_DIR}/evolution${SUFFIX}.txt"
    log_message "Credenciais da Evolution API salvas em ${CREDENTIALS_DIR}/evolution${SUFFIX}.txt"
else
    log_error "Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console."
fi

# Criar um objeto JSON de saída para o relatório local
cat << EOF > /tmp/evolution${SUFFIX}_output.json
{
  "url": "https://${EVOLUTION_DOMAIN}",
  "apiKey": "${API_KEY}",
  "managerUrl": "https://${EVOLUTION_DOMAIN}/manager",
  "redisStackName": "${REDIS_STACK_NAME}",
  "postgresStackName": "${PG_STACK_NAME}",
  "evolutionStackName": "${EVO_STACK_NAME}",
  "databaseUri": "postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres${SUFFIX}:5432/evolution${SUFFIX}"
}
EOF

log_message "Arquivo JSON de saída criado em /tmp/evolution${SUFFIX}_output.json"

# Enviar webhook com logs de sucesso
send_webhook_with_logs "success" "Instalação da Evolution API concluída com sucesso"

echo "---------------------------------------------"
echo -e "${VERDE}[ EVOLUTION API - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}URL da API:${RESET} https://${EVOLUTION_DOMAIN}"
echo -e "${VERDE}API Key:${RESET} ${API_KEY}"
echo -e "${VERDE}Link do Manager:${RESET} https://${EVOLUTION_DOMAIN}/manager"
echo -e "${VERDE}Stacks criadas com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${REDIS_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${PG_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${EVO_STACK_NAME}${RESET}"
echo -e "${VERDE}As stacks estão disponíveis e editáveis no Portainer.${RESET}"

log_message "Instalação concluída com sucesso!"
