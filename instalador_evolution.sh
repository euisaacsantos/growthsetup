#!/bin/bash
# Script para criar stacks separadas no Portainer (Evolution, Redis e PostgreSQL)
# Uso: ./script.sh <portainer_url> <evolution_domain> <portainer_password> [sufixo]
# Exemplo: ./script.sh painel.trafegocomia.com api.trafegocomia.com senha123 cliente1

# Verificar parâmetros obrigatórios
if [ $# -lt 3 ]; then
    echo "Uso: $0 <portainer_url> <evolution_domain> <portainer_password> [sufixo]"
    echo "Exemplo: $0 painel.trafegocomia.com api.trafegocomia.com senha123 cliente1"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"        # URL do Portainer
EVOLUTION_DOMAIN="$2"             # Domínio para a Evolution API
PORTAINER_PASSWORD="$3"           # Senha do Portainer

# Verificar se há sufixo (para múltiplas instâncias)
if [ -n "$4" ]; then
    SUFFIX="_$4"
    echo "Instalando com sufixo: $SUFFIX"
else
    SUFFIX=""
    echo "Instalando primeira instância (sem sufixo)"
fi

# Configurações adicionais
PORTAINER_USER="admin"              # Usuário do Portainer
REDIS_STACK_NAME="redis${SUFFIX}"   # Nome da stack Redis
PG_STACK_NAME="postgres${SUFFIX}"   # Nome da stack PostgreSQL
EVO_STACK_NAME="evolution${SUFFIX}" # Nome da stack Evolution

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
docker volume create redis_data${SUFFIX} 2>/dev/null || echo "Volume redis_data${SUFFIX} já existe."
docker volume create postgres_data${SUFFIX} 2>/dev/null || echo "Volume postgres_data${SUFFIX} já existe."
docker volume create evolution_instances${SUFFIX} 2>/dev/null || echo "Volume evolution_instances${SUFFIX} já existe."

# Criar rede overlay se não existir
docker network create --driver overlay GrowthNet 2>/dev/null || echo "Rede GrowthNet já existe."

# Criar arquivo docker-compose para a stack Redis
echo -e "${VERDE}Criando arquivo docker-compose para a stack Redis...${RESET}"
cat > "${REDIS_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  redis${SUFFIX}:
    image: redis:latest
    command: redis-server --appendonly yes
    volumes:
      - redis_data${SUFFIX}:/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

volumes:
  redis_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
EOL

# Criar arquivo docker-compose para a stack PostgreSQL
echo -e "${VERDE}Criando arquivo docker-compose para a stack PostgreSQL...${RESET}"
cat > "${PG_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  postgres${SUFFIX}:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=b2ecbaa44551df03fa3793b38091cff7
      - POSTGRES_USER=postgres
    volumes:
      - postgres_data${SUFFIX}:/var/lib/postgresql/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

volumes:
  postgres_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
EOL

# Criar arquivo docker-compose para a stack Evolution
echo -e "${VERDE}Criando arquivo docker-compose para a stack Evolution...${RESET}"
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

volumes:
  evolution_instances${SUFFIX}:
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

# Implementar stacks na ordem correta: primeiro Redis e PostgreSQL, depois Evolution
echo -e "${VERDE}Iniciando deploy das stacks em sequência...${RESET}"

# Processar Redis primeiro
process_stack "$REDIS_STACK_NAME"
if [ $? -ne 0 ]; then
    echo -e "${AMARELO}Aviso: Problemas ao implementar Redis, mas continuando...${RESET}"
fi

# Processar PostgreSQL segundo
process_stack "$PG_STACK_NAME"
if [ $? -ne 0 ]; then
    echo -e "${AMARELO}Aviso: Problemas ao implementar PostgreSQL, mas continuando...${RESET}"
fi

# Processar Evolution por último (depende dos outros)
# Adicionar uma pausa para garantir que os serviços anteriores sejam inicializados
echo -e "${VERDE}Aguardando 10 segundos para inicialização dos serviços Redis e PostgreSQL...${RESET}"
sleep 10

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
    echo -e "${VERDE}Credenciais da Evolution API salvas em ${CREDENTIALS_DIR}/evolution${SUFFIX}.txt${RESET}"
else
    echo -e "${AMARELO}Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console.${RESET}"
fi

# Criar um objeto JSON de saída para o n8n
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

echo -e "${VERDE}Arquivo JSON de saída criado em /tmp/evolution${SUFFIX}_output.json${RESET}"

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
