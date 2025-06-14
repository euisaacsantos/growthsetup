#!/bin/bash
# Script para criar stack do MinIO no Portainer
# Uso: ./script.sh <portainer_url> <minio_console_domain> <minio_api_domain> <portainer_password> [sufixo] [id-xxxx]
# Exemplo: ./script.sh painel.trafegocomia.com console.storage.com.br api.storage.com.br senha123 cliente1 id-12341221125
# Sem sufixo: ./script.sh painel.trafegocomia.com console.storage.com.br api.storage.com.br senha123 "" id-12341221125

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
  "console_link": "https://${MINIO_CONSOLE_DOMAIN}",
  "api_link": "https://${MINIO_API_DOMAIN}",
  "root_user": "${MINIO_ROOT_USER}",
  "root_password": "${MINIO_ROOT_PASSWORD}",
  "minio": {
    "console_domain": "${MINIO_CONSOLE_DOMAIN}",
    "api_domain": "${MINIO_API_DOMAIN}",
    "root_user": "${MINIO_ROOT_USER}",
    "root_password": "${MINIO_ROOT_PASSWORD}",
    "access_key": "${MINIO_ROOT_USER}",
    "secret_key": "${MINIO_ROOT_PASSWORD}"
  },
  "stacks": {
    "minio": "${MINIO_STACK_NAME}"
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
log_message "Iniciando instalação do MinIO..."

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    error_exit "Parâmetros insuficientes. Uso: $0 <portainer_url> <minio_console_domain> <minio_api_domain> <portainer_password> [sufixo] [id-xxxx]"
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
MINIO_CONSOLE_DOMAIN="$2"            # Domínio para o console MinIO
MINIO_API_DOMAIN="$3"                # Domínio para a API MinIO
PORTAINER_PASSWORD="$4"              # Senha do Portainer

log_message "Parâmetros recebidos: Portainer=$1, Console=${MINIO_CONSOLE_DOMAIN}, API=${MINIO_API_DOMAIN}"

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
PORTAINER_USER="admin"               # Usuário do Portainer
MINIO_STACK_NAME="minio${SUFFIX}"    # Nome da stack MinIO

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar credenciais do MinIO
generate_minio_password() {
    # Gerar senha de 16 caracteres com letras, números e símbolos
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
}

MINIO_ROOT_USER="admin${SUFFIX}"
MINIO_ROOT_PASSWORD=$(generate_minio_password)
log_message "Credenciais do MinIO geradas - Usuário: ${MINIO_ROOT_USER}, Senha: ${MINIO_ROOT_PASSWORD}"

# Criar volumes Docker necessários
log_message "Criando volumes Docker..."
docker volume create minio_data${SUFFIX} 2>/dev/null || log_message "Volume minio_data${SUFFIX} já existe."
docker volume create minio_config${SUFFIX} 2>/dev/null || log_message "Volume minio_config${SUFFIX} já existe."

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

# Criar arquivo docker-compose para a stack MinIO
log_message "Criando arquivo docker-compose para a stack MinIO..."
cat > "${MINIO_STACK_NAME}.yaml" <<EOL
version: '3.7'

services:
  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    networks:
      - GrowthNet
    environment:
      # Credenciais do MinIO
      - MINIO_ROOT_USER=${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
      
      # Configurações do servidor
      - MINIO_REGION_NAME=us-east-1
      - MINIO_BROWSER_REDIRECT_URL=https://${MINIO_CONSOLE_DOMAIN}
      - MINIO_SERVER_URL=https://${MINIO_API_DOMAIN}
      
      # Configurações de saúde
      - MINIO_PROMETHEUS_AUTH_TYPE=public
      
      # Timezone
      - TZ=America/Sao_Paulo
    volumes:
      - minio_data${SUFFIX}:/data
      - minio_config${SUFFIX}:/root/.minio
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
        reservations:
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
      labels:
        # Console MinIO (porta 9001)
        - traefik.enable=true
        - traefik.docker.network=GrowthNet
        
        # Roteamento para o Console MinIO
        - "traefik.http.routers.minio_console${SUFFIX}.rule=Host(\`${MINIO_CONSOLE_DOMAIN}\`)"
        - traefik.http.routers.minio_console${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.minio_console${SUFFIX}.tls=true
        - traefik.http.routers.minio_console${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.minio_console${SUFFIX}.priority=2
        - traefik.http.routers.minio_console${SUFFIX}.service=minio_console${SUFFIX}
        - traefik.http.services.minio_console${SUFFIX}.loadbalancer.server.port=9001
        - traefik.http.services.minio_console${SUFFIX}.loadbalancer.passHostHeader=1
        
        # Roteamento para a API MinIO (porta 9000)
        - "traefik.http.routers.minio_api${SUFFIX}.rule=Host(\`${MINIO_API_DOMAIN}\`)"
        - traefik.http.routers.minio_api${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.minio_api${SUFFIX}.tls=true
        - traefik.http.routers.minio_api${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.minio_api${SUFFIX}.priority=1
        - traefik.http.routers.minio_api${SUFFIX}.service=minio_api${SUFFIX}
        - traefik.http.services.minio_api${SUFFIX}.loadbalancer.server.port=9000
        - traefik.http.services.minio_api${SUFFIX}.loadbalancer.passHostHeader=1
        
        # Headers necessários para o MinIO
        - traefik.http.routers.minio_api${SUFFIX}.middlewares=minio_headers${SUFFIX}
        - traefik.http.middlewares.minio_headers${SUFFIX}.headers.accesscontrolalloworiginlist=*
        - traefik.http.middlewares.minio_headers${SUFFIX}.headers.accesscontrolallowmethods=GET,PUT,POST,DELETE,HEAD
        - traefik.http.middlewares.minio_headers${SUFFIX}.headers.accesscontrolallowheaders=*

    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
      start_period: 60s

volumes:
  minio_data${SUFFIX}:
    external: true
  minio_config${SUFFIX}:
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

# Implementar stack do MinIO
log_message "Iniciando deploy da stack MinIO..."
process_stack "$MINIO_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack MinIO."
fi

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    # Cria o arquivo de credenciais separadamente para evitar problemas com a saída
    cat > "${CREDENTIALS_DIR}/minio${SUFFIX}.txt" << EOF
MinIO Information
Console URL: https://${MINIO_CONSOLE_DOMAIN}
API URL: https://${MINIO_API_DOMAIN}
Root User: ${MINIO_ROOT_USER}
Root Password: ${MINIO_ROOT_PASSWORD}
Access Key: ${MINIO_ROOT_USER}
Secret Key: ${MINIO_ROOT_PASSWORD}
EOF
    chmod 600 "${CREDENTIALS_DIR}/minio${SUFFIX}.txt"
    log_message "Credenciais do MinIO salvas em ${CREDENTIALS_DIR}/minio${SUFFIX}.txt"
else
    log_error "Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console."
fi

# Criar um objeto JSON de saída para integração com outros sistemas
cat << EOF > /tmp/minio${SUFFIX}_output.json
{
  "consoleUrl": "https://${MINIO_CONSOLE_DOMAIN}",
  "apiUrl": "https://${MINIO_API_DOMAIN}",
  "rootUser": "${MINIO_ROOT_USER}",
  "rootPassword": "${MINIO_ROOT_PASSWORD}",
  "accessKey": "${MINIO_ROOT_USER}",
  "secretKey": "${MINIO_ROOT_PASSWORD}",
  "minioStackName": "${MINIO_STACK_NAME}",
  "region": "us-east-1"
}
EOF

log_message "Arquivo JSON de saída criado em /tmp/minio${SUFFIX}_output.json"

# Aguardar inicialização do serviço
log_message "Aguardando 30 segundos para inicialização do MinIO..."
sleep 30

# Enviar webhook com logs de sucesso
send_webhook_with_logs "success" "Instalação do MinIO concluída com sucesso"

echo "---------------------------------------------"
echo -e "${VERDE}[ MinIO - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}Console URL:${RESET} https://${MINIO_CONSOLE_DOMAIN}"
echo -e "${VERDE}API URL:${RESET} https://${MINIO_API_DOMAIN}"
echo -e "${VERDE}Root User:${RESET} ${MINIO_ROOT_USER}"
echo -e "${VERDE}Root Password:${RESET} ${MINIO_ROOT_PASSWORD}"
echo -e "${VERDE}Access Key:${RESET} ${MINIO_ROOT_USER}"
echo -e "${VERDE}Secret Key:${RESET} ${MINIO_ROOT_PASSWORD}"
echo -e "${VERDE}Stack criada com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${MINIO_STACK_NAME}${RESET}"
echo -e "${VERDE}Acesse o console MinIO através do endereço:${RESET} https://${MINIO_CONSOLE_DOMAIN}"
echo -e "${VERDE}Endpoint da API S3:${RESET} https://${MINIO_API_DOMAIN}"
echo -e "${VERDE}A stack está disponível e editável no Portainer.${RESET}"

log_message "Instalação concluída com sucesso!"
