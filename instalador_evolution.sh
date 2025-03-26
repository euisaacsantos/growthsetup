#!/bin/bash
# Script para criar stack Evolution, Redis e PostgreSQL via API do Portainer

# Configurações
PORTAINER_URL="https://painel.trafegocomia.com"  # URL do seu Portainer
PORTAINER_USER="admin"                  # Seu usuário do Portainer
PORTAINER_PASSWORD="suasenha"           # Sua senha do Portainer (altere aqui)
STACK_NAME="evolution-stack"            # Nome da stack

# Gerar uma chave API aleatória para a Evolution
API_KEY=$(openssl rand -hex 16)
echo "Chave API gerada: $API_KEY"

# Criar volumes (opcional, se você tiver acesso ao Docker direto)
if command -v docker &> /dev/null; then
    echo "Criando volumes Docker..."
    docker volume create redis_data 2>/dev/null || echo "Volume redis_data já existe."
    docker volume create postgres_data 2>/dev/null || echo "Volume postgres_data já existe."
    docker volume create evolution_instances 2>/dev/null || echo "Volume evolution_instances já existe."
    
    # Criar rede (opcional)
    docker network create --driver overlay GrowthNet 2>/dev/null || echo "Rede GrowthNet já existe."
else
    echo "Docker não encontrado. Os volumes precisarão ser criados manualmente."
fi

# Conteúdo do Docker Compose para a stack
DOCKER_COMPOSE=$(cat <<EOF
version: '3.7'
services:
  redis:
    image: redis:latest
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

  postgres:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=b2ecbaa44551df03fa3793b38091cff7
      - POSTGRES_USER=postgres
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

  evolution:
    image: atendai/evolution-api:latest
    volumes:
      - evolution_instances:/evolution/instances
    networks:
      - GrowthNet
    environment:
      - SERVER_URL=https://api.trafegocomia.com
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
      - DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
      - DATABASE_CONNECTION_CLIENT_NAME=evolution
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
      - CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/chatwoot?sslmode=disable
      - CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=false
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://redis:6379/8
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
      - traefik.http.routers.evolution.rule=Host(\`api.trafegocomia.com\`)
      - traefik.http.routers.evolution.entrypoints=websecure
      - traefik.http.routers.evolution.priority=1
      - traefik.http.routers.evolution.tls.certresolver=letsencryptresolver
      - traefik.http.routers.evolution.service=evolution
      - traefik.http.services.evolution.loadbalancer.server.port=8080

volumes:
  redis_data:
    external: true
  postgres_data:
    external: true
  evolution_instances:
    external: true

networks:
  GrowthNet:
    external: true
EOF
)

# Função para exibir erros e sair
error_exit() {
    echo "ERRO: $1" >&2
    exit 1
}

# Obter token JWT do Portainer
echo "Autenticando no Portainer..."
echo "URL do Portainer: $PORTAINER_URL"

# Usar curl com a opção -k para ignorar verificação de certificado
AUTH_RESPONSE=$(curl -k -s -X POST "${PORTAINER_URL}/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${PORTAINER_USER}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')

echo "Código HTTP retornado: ${HTTP_CODE}"

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

echo "Autenticação bem-sucedida. Token JWT obtido."

# Listar endpoints disponíveis
echo "Listando endpoints disponíveis..."
ENDPOINTS_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/endpoints" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$ENDPOINTS_RESPONSE" | tail -n1)
ENDPOINTS_BODY=$(echo "$ENDPOINTS_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
    error_exit "Falha ao listar endpoints. Código HTTP: ${HTTP_CODE}, Resposta: ${ENDPOINTS_BODY}"
fi

echo "Endpoints disponíveis:"
echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*,"Name":"[^"]*' | sed 's/"Id":\([0-9]*\),"Name":"\([^"]*\)"/ID: \1, Nome: \2/'

# Solicitar ID do endpoint
echo ""
echo "Por favor, informe o ID do endpoint que deseja usar (número ID mostrado acima):"
read -p "ID do endpoint: " PORTAINER_ENDPOINT_ID

if [ -z "$PORTAINER_ENDPOINT_ID" ]; then
    # Tentar extrair automaticamente o primeiro endpoint
    PORTAINER_ENDPOINT_ID=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*' | head -1 | grep -o '[0-9]*')
    
    if [ -z "$PORTAINER_ENDPOINT_ID" ]; then
        error_exit "Nenhum ID de endpoint fornecido e não foi possível extrair automaticamente."
    else
        echo "Usando o primeiro endpoint disponível (ID: $PORTAINER_ENDPOINT_ID)"
    fi
fi

# Verificar se o endpoint está em Swarm mode
echo "Verificando se o endpoint está em modo Swarm..."
SWARM_RESPONSE=$(curl -k -s -X GET "${PORTAINER_URL}/api/endpoints/${PORTAINER_ENDPOINT_ID}/docker/swarm" \
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

echo "ID do Swarm: ${SWARM_ID}"

# Criar a stack via API do Portainer
echo "Criando stack ${STACK_NAME}..."

# Verificar se jq está instalado
if ! command -v jq &> /dev/null; then
    echo "jq não está instalado. Instalando..."
    apt-get update && apt-get install -y jq || {
        echo "Falha ao instalar jq. Tentando outra abordagem..."
        DOCKER_COMPOSE_ESC=$(echo "$DOCKER_COMPOSE" | sed 's/"/\\"/g' | tr -d '\n')
        PAYLOAD="{\"Name\":\"${STACK_NAME}\",\"StackFileContent\":\"$DOCKER_COMPOSE_ESC\",\"SwarmID\":\"${SWARM_ID}\"}"
    }
else
    PAYLOAD="{\"Name\":\"${STACK_NAME}\",\"StackFileContent\":$(echo "$DOCKER_COMPOSE" | jq -R -s .),\"SwarmID\":\"${SWARM_ID}\"}"
fi

echo "Enviando requisição para criar stack..."
STACK_RESPONSE=$(curl -k -s -X POST "${PORTAINER_URL}/api/stacks?type=1&method=string&endpointId=${PORTAINER_ENDPOINT_ID}" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$STACK_RESPONSE" | tail -n1)
STACK_BODY=$(echo "$STACK_RESPONSE" | sed '$d')

echo "Código HTTP da criação da stack: $HTTP_CODE"
if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 201 ]; then
    echo "Resposta completa:"
    echo "$STACK_BODY"
    error_exit "Falha ao criar a stack. Código HTTP: ${HTTP_CODE}"
fi

echo "Stack criada com sucesso!"

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    cat > "${CREDENTIALS_DIR}/evolution.txt" << EOF
Evolution API Information
URL: https://api.trafegocomia.com
API Key: ${API_KEY}
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF
    chmod 600 "${CREDENTIALS_DIR}/evolution.txt"
    echo "Credenciais da Evolution API salvas em ${CREDENTIALS_DIR}/evolution.txt"
else
    echo "Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console."
fi

echo "---------------------------------------------"
echo "API Key: $API_KEY"
echo "Stack ${STACK_NAME} criada com sucesso via API do Portainer!"
echo "A stack deve aparecer no Portainer imediatamente."
