#!/bin/bash
# Script para criar stacks separadas para n8n no Portainer (n8n, Redis e PostgreSQL)
# Uso: ./script.sh <portainer_url> <n8n_editor_domain> <n8n_webhook_domain> <portainer_password> [sufixo] [id-xxxx]
# Exemplo: ./script.sh painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 cliente1 id-12341221125
# Sem sufixo: ./script.sh painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 "" id-12341221125

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    echo "Uso: $0 <portainer_url> <n8n_editor_domain> <n8n_webhook_domain> <portainer_password> [sufixo] [id-xxxx]"
    echo "Exemplo: $0 painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 cliente1 id-12341221125"
    echo "Sem sufixo: $0 painel.trafegocomia.com editor.growthtap.com.br webhook.growthtap.com.br senha123 \"\" id-12341221125"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
N8N_EDITOR_DOMAIN="$2"               # Domínio para o editor n8n
N8N_WEBHOOK_DOMAIN="$3"              # Domínio para webhook n8n
PORTAINER_PASSWORD="$4"              # Senha do Portainer

# Inicializar variáveis
SUFFIX=""
INSTALLATION_ID="sem_id"
WEBHOOK_URL="https://setup.growthtap.com.br/webhook/bf813e80-f036-400b-acae-904d703df6dd"

# Processar parâmetros opcionais (sufixo e ID)
for param in "${@:5}"; do
    # Verificar se o parâmetro começa com 'id-'
    if [[ "$param" == id-* ]]; then
        INSTALLATION_ID="${param#id-}"  # Remover o prefixo 'id-'
        echo "ID da instalação: $INSTALLATION_ID"
    # Se não for vazio e não começar com 'id-', é o sufixo
    elif [ -n "$param" ]; then
        SUFFIX="_$param"
        echo "Instalando com sufixo: $SUFFIX"
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

# Função para gerar uma senha segura
generate_secure_password() {
    # Gerar senha com pelo menos 1 número, 1 letra maiúscula e 1 letra minúscula
    local length=12
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1)
    
    # Garantir que tenha pelo menos um número
    if ! [[ $password =~ [0-9] ]]; then
        # Substituir um caractere aleatório por um número
        local pos=$((RANDOM % $length))
        local num=$((RANDOM % 10))
        password=$(echo $password | sed s/./\${num}/$pos/)
    fi
    
    # Garantir que tenha pelo menos uma letra maiúscula
    if ! [[ $password =~ [A-Z] ]]; then
        # Substituir um caractere aleatório por uma letra maiúscula
        local pos=$((RANDOM % $length))
        local upper=$(echo "ABCDEFGHIJKLMNOPQRSTUVWXYZ" | fold -w1 | shuf | head -n1)
        password=$(echo $password | sed s/./\${upper}/$pos/)
    fi
    
    echo $password
}

# Verificar se já existe uma chave de criptografia no volume n8n_data
echo -e "${VERDE}Verificando se já existe uma chave de criptografia...${RESET}"
EXISTING_KEY=""

# Tenta extrair a chave existente de um container temporário
if docker volume inspect n8n_data${SUFFIX} &>/dev/null; then
    echo -e "${AMARELO}Volume n8n_data${SUFFIX} já existe. Tentando extrair a chave existente...${RESET}"
    
    # Criar um container temporário para acessar o arquivo de configuração
    docker run --rm -v n8n_data${SUFFIX}:/data alpine:latest sh -c "if [ -f /data/.n8n/config ]; then cat /data/.n8n/config | grep -o '\"encryptionKey\":\"[^\"]*\"' | cut -d '\"' -f 4; fi" > /tmp/existing_key_output.txt
    
    EXISTING_KEY=$(cat /tmp/existing_key_output.txt)
    rm -f /tmp/existing_key_output.txt
    
    if [ -n "$EXISTING_KEY" ]; then
        echo -e "${VERDE}Chave de criptografia existente encontrada. Usando-a em vez de gerar uma nova.${RESET}"
        N8N_ENCRYPTION_KEY=$EXISTING_KEY
    else
        echo -e "${AMARELO}Não foi possível extrair a chave existente ou o arquivo de configuração não existe.${RESET}"
        echo -e "${VERDE}Gerando uma nova chave de criptografia...${RESET}"
        N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
    fi
else
    echo -e "${VERDE}Volume n8n_data${SUFFIX} não existe. Gerando uma nova chave de criptografia...${RESET}"
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
fi

echo -e "${VERDE}Chave de criptografia do n8n: ${RESET}${N8N_ENCRYPTION_KEY}"

# Gerar uma senha sugerida para o n8n
N8N_SUGGESTED_PASSWORD=$(generate_secure_password)
echo -e "${VERDE}Senha sugerida para o n8n: ${RESET}${N8N_SUGGESTED_PASSWORD}"

# Gerar uma senha do PostgreSQL aleatória
POSTGRES_PASSWORD=$(openssl rand -hex 16)
echo -e "${VERDE}Senha do PostgreSQL gerada: ${RESET}${POSTGRES_PASSWORD}"

# Função para exibir erros e sair
error_exit() {
    echo -e "${VERMELHO}ERRO: $1${RESET}" >&2
    exit 1
}

# Criar volumes Docker necessários
echo -e "${VERDE}Criando volumes Docker...${RESET}"
docker volume create n8n_data${SUFFIX} 2>/dev/null || echo "Volume n8n_data${SUFFIX} já existe."
docker volume create n8n_postgres_data${SUFFIX} 2>/dev/null || echo "Volume n8n_postgres_data${SUFFIX} já existe."
docker volume create n8n_redis_data${SUFFIX} 2>/dev/null || echo "Volume n8n_redis_data${SUFFIX} já existe."

# Verificar se a rede GrowthNet existe, caso contrário, criar
docker network inspect GrowthNet >/dev/null 2>&1 || {
    echo -e "${VERDE}Criando rede GrowthNet...${RESET}"
    # Criar a rede como attachable para permitir conexão direta para testes
    docker network create --driver overlay --attachable GrowthNet
}

# Criar arquivo docker-compose para a stack Redis
echo -e "${VERDE}Criando arquivo docker-compose para a stack Redis...${RESET}"
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
echo -e "${VERDE}Criando arquivo docker-compose para a stack PostgreSQL...${RESET}"
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
echo -e "${VERDE}Criando arquivo docker-compose para a stack n8n...${RESET}"
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
if ! command -v jq &> /dev/null; then
    echo -e "${VERDE}Instalando jq...${RESET}"
    apt-get update && apt-get install -y jq || {
        error_exit "Falha ao instalar jq. Necessário para processamento de JSON."
    }
fi

# Obter token JWT do Portainer
echo -e "${VERDE}Autenticando no Portainer...${RESET}"
echo -e "URL do Portainer: ${BEGE}${PORTAINER_URL}${RESET}"

# Usar curl com a opção -k para ignorar verificação de certificado
AUTH_RESPONSE=$(curl -k -s -X POST "${PORTAINER_URL}/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')

echo -e "Código HTTP retornado: ${BEGE}${HTTP_CODE}${RESET}"

if [ "$HTTP_CODE" -ne 200 ]; then
    echo "Erro na autenticação. Resposta completa:"
    echo "$AUTH_RESPONSE"
    
    # Tentar alternativa com HTTP em vez de HTTPS
    PORTAINER_URL_HTTP=$(echo "$PORTAINER_URL" | sed 's/https:/http:/')
    echo "Tentando alternativa com HTTP: ${PORTAINER_URL_HTTP}/api/auth"
    
    AUTH_RESPONSE=$(curl -s -X POST "${PORTAINER_URL_HTTP}/api/auth" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
        -w "\n%{http_code}")
    
    HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
    AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')
    
    echo "Código HTTP alternativo: ${HTTP_CODE}"
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        error_exit "Autenticação falhou. Verifique a URL, usuário e senha do Portainer."
    else
        echo "Conexão bem-sucedida usando HTTP. Continuando com HTTP..."
        PORTAINER_URL="$PORTAINER_URL_HTTP"
    fi
fi

JWT_TOKEN=$(echo "$AUTH_BODY" | grep -o '"jwt":"[^"]*' | cut -d'"' -f4)

if [ -z "$JWT_TOKEN" ]; then
    error_exit "Não foi possível extrair o token JWT da resposta: $AUTH_BODY"
fi

echo -e "${VERDE}Autenticação bem-sucedida. Token JWT obtido.${RESET}"

# Listar endpoints disponíveis
echo -e "${VERDE}Listando endpoints disponíveis...${RESET}"
ENDPOINTS_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/endpoints" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$ENDPOINTS_RESPONSE" | tail -n1)
ENDPOINTS_BODY=$(echo "$ENDPOINTS_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
    error_exit "Falha ao listar endpoints. Código HTTP: ${HTTP_CODE}, Resposta: ${ENDPOINTS_BODY}"
fi

echo -e "${VERDE}Endpoints disponíveis:${RESET}"
ENDPOINTS_LIST=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*,"Name":"[^"]*' | sed 's/"Id":\([0-9]*\),"Name":"\([^"]*\)"/ID: \1, Nome: \2/')
echo "$ENDPOINTS_LIST"

# Selecionar automaticamente o primeiro endpoint disponível
ENDPOINT_ID=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*' | head -1 | grep -o '[0-9]*')
    
if [ -z "$ENDPOINT_ID" ]; then
    error_exit "Não foi possível determinar o ID do endpoint."
else
    echo -e "Usando o primeiro endpoint disponível (ID: ${BEGE}${ENDPOINT_ID}${RESET})"
fi

# Verificar se o endpoint está em Swarm mode
echo -e "${VERDE}Verificando se o endpoint está em modo Swarm...${RESET}"
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

echo -e "ID do Swarm: ${BEGE}${SWARM_ID}${RESET}"

# Função para processar a criação ou atualização de uma stack
process_stack() {
    local stack_name=$1
    local yaml_file="${stack_name}.yaml"
    
    echo -e "${VERDE}Processando stack: ${BEGE}${stack_name}${RESET}"
    
    # Verificar se a stack já existe
    STACK_LIST_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/stacks" \
        -H "Authorization: Bearer ${JWT_TOKEN}" \
        -w "\n%{http_code}")

    HTTP_CODE=$(echo "$STACK_LIST_RESPONSE" | tail -n1)
    STACK_LIST_BODY=$(echo "$STACK_LIST_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo -e "${AMARELO}Aviso: Não foi possível verificar stacks existentes. Código HTTP: ${HTTP_CODE}${RESET}"
        echo "Continuando mesmo assim..."
    else
        # Verificar se uma stack com o mesmo nome já existe
        EXISTING_STACK_ID=$(echo "$STACK_LIST_BODY" | grep -o "\"Id\":[0-9]*,\"Name\":\"${stack_name}\"" | grep -o '"Id":[0-9]*' | grep -o '[0-9]*')
        
        if [ ! -z "$EXISTING_STACK_ID" ]; then
            echo -e "${AMARELO}Uma stack com o nome '${stack_name}' já existe (ID: ${EXISTING_STACK_ID})${RESET}"
            echo -e "${VERDE}Removendo a stack existente para recriá-la...${RESET}"
            
            # Remover a stack existente
            DELETE_RESPONSE=$(curl -k -s -X DELETE "${PORTAINER_URL}/api/stacks/${EXISTING_STACK_ID}?endpointId=${ENDPOINT_ID}" \
                -H "Authorization: Bearer ${JWT_TOKEN}" \
                -w "\n%{http_code}")
            
            HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -n1)
            DELETE_BODY=$(echo "$DELETE_RESPONSE" | sed '$d')
            
            if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 204 ]; then
                echo -e "${AMARELO}Aviso: Não foi possível remover a stack existente. Código HTTP: ${HTTP_CODE}${RESET}"
                echo "Continuando mesmo assim..."
            else
                echo -e "${VERDE}Stack existente removida com sucesso.${RESET}"
            fi
            
            # Aguardar um momento para garantir que a stack foi removida
            sleep 3
        fi
    fi

    # Criar arquivo temporário para capturar a saída de erro e a resposta
    erro_output=$(mktemp)
    response_output=$(mktemp)

    # Enviar a stack usando o endpoint multipart do Portainer
    echo -e "${VERDE}Enviando a stack ${stack_name} para o Portainer...${RESET}"
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
            echo -e "${VERDE}Deploy da stack ${BEGE}${stack_name}${RESET}${VERDE} feito com sucesso!${RESET}"
            return 0
        else
            echo -e "${VERMELHO}Erro, resposta inesperada do servidor ao tentar efetuar deploy da stack ${BEGE}${stack_name}${RESET}.${RESET}"
            echo "Resposta do servidor: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
        fi
    else
        echo -e "${VERMELHO}Erro ao efetuar deploy. Resposta HTTP: ${http_code}${RESET}"
        echo "Mensagem de erro: $(cat "$erro_output")"
        echo "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
        
        # Tentar método alternativo se falhar
        echo -e "${AMARELO}Tentando método alternativo de deploy...${RESET}"
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
            echo -e "${VERDE}Deploy da stack ${BEGE}${stack_name}${RESET}${VERDE} feito com sucesso (método alternativo)!${RESET}"
            return 0
        else
            echo -e "${VERMELHO}Erro ao efetuar deploy pelo método alternativo. Resposta HTTP: ${http_code}${RESET}"
            echo "Mensagem de erro: $(cat "$erro_output")"
            echo "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
            
            # Último recurso - usar o Docker diretamente
            echo -e "${AMARELO}Tentando deploy direto via Docker Swarm...${RESET}"
            if docker stack deploy --prune --resolve-image always -c "${yaml_file}" "${stack_name}"; then
                echo -e "${VERDE}Deploy da stack ${BEGE}${stack_name}${RESET}${VERDE} feito com sucesso via Docker Swarm!${RESET}"
                echo -e "${AMARELO}Nota: A stack pode não ser editável no Portainer.${RESET}"
                return 0
            else
                echo -e "${VERMELHO}Falha em todos os métodos de deploy da stack ${stack_name}.${RESET}"
                return 1
            fi
        fi
    fi

    # Remove os arquivos temporários
    rm -f "$erro_output" "$response_output"
}
