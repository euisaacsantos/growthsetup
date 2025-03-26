#!/bin/bash
# Script para criar stack editável no Portainer (Evolution API + Redis + PostgreSQL)

# Configurações
PORTAINER_URL="https://painel.trafegocomia.com" # URL do Portainer (sem https://)
PORTAINER_USER="admin"                          # Usuário do Portainer
PORTAINER_PASSWORD="suasenha"                   # Senha do Portainer
STACK_NAME="evolution-stack"                    # Nome da stack
EVOLUTION_DOMAIN="api.trafegocomia.com"         # Domínio para a Evolution API

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar uma chave API aleatória para a Evolution
API_KEY=$(openssl rand -hex 16)
echo -e "${VERDE}Chave API gerada: ${RESET}${API_KEY}"

# Função para exibir erros e sair
error_exit() {
    echo -e "${VERMELHO}ERRO: $1${RESET}" >&2
    exit 1
}

# Criar volumes Docker necessários
echo -e "${VERDE}Criando volumes Docker...${RESET}"
docker volume create redis_data 2>/dev/null || echo "Volume redis_data já existe."
docker volume create postgres_data 2>/dev/null || echo "Volume postgres_data já existe."
docker volume create evolution_instances 2>/dev/null || echo "Volume evolution_instances já existe."

# Criar rede overlay se não existir
docker network create --driver overlay GrowthNet 2>/dev/null || echo "Rede GrowthNet já existe."

# Criar arquivo docker-compose para a stack
echo -e "${VERDE}Criando arquivo docker-compose para a stack...${RESET}"
cat > "${STACK_NAME}.yaml" <<EOL
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
      - traefik.http.routers.evolution.rule=Host(\`${EVOLUTION_DOMAIN}\`)
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

# Solicitar ID do endpoint
echo ""
echo -e "${VERDE}Por favor, informe o ID do endpoint que deseja usar (número ID mostrado acima):${RESET}"
read -p "ID do endpoint: " ENDPOINT_ID

if [ -z "$ENDPOINT_ID" ]; then
    # Tentar extrair automaticamente o primeiro endpoint
    ENDPOINT_ID=$(echo "$ENDPOINTS_BODY" | grep -o '"Id":[0-9]*' | head -1 | grep -o '[0-9]*')
    
    if [ -z "$ENDPOINT_ID" ]; then
        error_exit "Nenhum ID de endpoint fornecido e não foi possível extrair automaticamente."
    else
        echo -e "Usando o primeiro endpoint disponível (ID: ${BEGE}${ENDPOINT_ID}${RESET})"
    fi
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

# Verificar se a stack já existe
echo -e "${VERDE}Verificando se já existe uma stack com o nome ${STACK_NAME}...${RESET}"
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
    EXISTING_STACK_ID=$(echo "$STACK_LIST_BODY" | grep -o "\"Id\":[0-9]*,\"Name\":\"${STACK_NAME}\"" | grep -o '"Id":[0-9]*' | grep -o '[0-9]*')
    
    if [ ! -z "$EXISTING_STACK_ID" ]; then
        echo -e "${AMARELO}Uma stack com o nome '${STACK_NAME}' já existe (ID: ${EXISTING_STACK_ID})${RESET}"
        echo "Opções:"
        echo "1. Atualizar a stack existente"
        echo "2. Criar uma nova stack com um nome diferente"
        echo "3. Sair"
        read -p "Escolha uma opção (1-3): " STACK_OPTION
        
        case $STACK_OPTION in
            1)
                echo -e "${VERDE}Atualizando stack existente...${RESET}"
                
                # Remover a stack existente
                echo -e "${VERDE}Removendo a stack existente para recriá-la...${RESET}"
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
                ;;
            2)
                echo -e "${VERDE}Criando stack com um novo nome...${RESET}"
                read -p "Informe o novo nome para a stack: " NEW_STACK_NAME
                if [ -z "$NEW_STACK_NAME" ]; then
                    NEW_STACK_NAME="${STACK_NAME}-$(date +%Y%m%d%H%M%S)"
                    echo -e "Usando nome gerado automaticamente: ${BEGE}${NEW_STACK_NAME}${RESET}"
                fi
                STACK_NAME="$NEW_STACK_NAME"
                
                # Atualizar o nome no arquivo yaml
                mv "${STACK_NAME}.yaml" "${NEW_STACK_NAME}.yaml"
                STACK_NAME="${NEW_STACK_NAME}"
                ;;
            3)
                echo -e "${VERDE}Operação cancelada pelo usuário.${RESET}"
                exit 0
                ;;
            *)
                error_exit "Opção inválida."
                ;;
        esac
    fi
fi

# Criar arquivo temporário para capturar a saída de erro e a resposta
erro_output=$(mktemp)
response_output=$(mktemp)

# Enviar a stack usando o endpoint multipart do Portainer
echo -e "${VERDE}Enviando a stack para o Portainer...${RESET}"
http_code=$(curl -s -o "$response_output" -w "%{http_code}" -k -X POST \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -F "Name=${STACK_NAME}" \
  -F "file=@$(pwd)/${STACK_NAME}.yaml" \
  -F "SwarmID=${SWARM_ID}" \
  -F "endpointId=${ENDPOINT_ID}" \
  "${PORTAINER_URL}/api/stacks/create/swarm/file" 2> "$erro_output")

response_body=$(cat "$response_output")

if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
    # Verifica o conteúdo da resposta para garantir que o deploy foi bem-sucedido
    if echo "$response_body" | grep -q "\"Id\""; then
        echo -e "${VERDE}Deploy da stack ${BEGE}${STACK_NAME}${RESET}${VERDE} feito com sucesso!${RESET}"
    else
        echo -e "${VERMELHO}Erro, resposta inesperada do servidor ao tentar efetuar deploy da stack ${BEGE}${STACK_NAME}${RESET}.${RESET}"
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
      -F "Name=${STACK_NAME}" \
      -F "file=@$(pwd)/${STACK_NAME}.yaml" \
      -F "SwarmID=${SWARM_ID}" \
      -F "endpointId=${ENDPOINT_ID}" \
      "${PORTAINER_URL}/api/stacks/create/file?endpointId=${ENDPOINT_ID}&type=1" 2> "$erro_output")
    
    response_body=$(cat "$response_output")
    
    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        echo -e "${VERDE}Deploy da stack ${BEGE}${STACK_NAME}${RESET}${VERDE} feito com sucesso (método alternativo)!${RESET}"
    else
        echo -e "${VERMELHO}Erro ao efetuar deploy pelo método alternativo. Resposta HTTP: ${http_code}${RESET}"
        echo "Mensagem de erro: $(cat "$erro_output")"
        echo "Detalhes: $(echo "$response_body" | jq . 2>/dev/null || echo "$response_body")"
        
        # Último recurso - usar o Docker diretamente
        echo -e "${AMARELO}Tentando deploy direto via Docker Swarm...${RESET}"
        if docker stack deploy --prune --resolve-image always -c "${STACK_NAME}.yaml" "${STACK_NAME}"; then
            echo -e "${VERDE}Deploy da stack ${BEGE}${STACK_NAME}${RESET}${VERDE} feito com sucesso via Docker Swarm!${RESET}"
            echo -e "${AMARELO}Nota: A stack pode não ser editável no Portainer.${RESET}"
        else
            error_exit "Falha em todos os métodos de deploy da stack."
        fi
    fi
fi

# Remove os arquivos temporários
rm -f "$erro_output" "$response_output"

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    cat > "${CREDENTIALS_DIR}/evolution.txt" << EOF
Evolution API Information
URL: https://${EVOLUTION_DOMAIN}
API Key: ${API_KEY}
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF
    chmod 600 "${CREDENTIALS_DIR}/evolution.txt"
    echo -e "${VERDE}Credenciais da Evolution API salvas em ${CREDENTIALS_DIR}/evolution.txt${RESET}"
else
    echo -e "${AMARELO}Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console.${RESET}"
fi

echo "---------------------------------------------"
echo -e "${VERDE}[ EVOLUTION API ]\n${RESET}"
echo -e "${VERDE}API URL:${RESET} https://${EVOLUTION_DOMAIN}"
echo -e "${VERDE}API Key:${RESET} ${API_KEY}"
echo -e "${VERDE}Stack ${STACK_NAME} criada com sucesso via API do Portainer!${RESET}"
echo -e "${VERDE}A stack deve aparecer no Portainer e ser editável.${RESET}"
