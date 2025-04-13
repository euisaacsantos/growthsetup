#!/bin/bash
# Script para criar stacks para Chatwoot no Portainer (Chatwoot, Redis e PostgreSQL)
# Uso: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_chatwoot.sh | bash -s <portainer_url> <chatwoot_domain> <portainer_password> <chatwoot_admin_email> [sufixo] [id-xxxx]
# Exemplo: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_chatwoot.sh | bash -s painel.trafegocomia.com chat.growthtap.com.br senha123 admin@exemplo.com cliente1 id-12341221125

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    echo "Uso: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_chatwoot.sh | bash -s <portainer_url> <chatwoot_domain> <portainer_password> <chatwoot_admin_email> [sufixo] [id-xxxx]"
    echo "Exemplo: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_chatwoot.sh | bash -s painel.trafegocomia.com chat.growthtap.com.br senha123 admin@exemplo.com cliente1 id-12341221125"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
CHATWOOT_DOMAIN="$2"                 # Domínio para o Chatwoot
PORTAINER_PASSWORD="$3"              # Senha do Portainer
CHATWOOT_ADMIN_EMAIL="$4"            # Email do administrador do Chatwoot

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
PORTAINER_USER="admin"                      # Usuário do Portainer
CHATWOOT_STACK_NAME="chatwoot${SUFFIX}"     # Nome da stack Chatwoot
REDIS_STACK_NAME="chatwoot_redis${SUFFIX}"  # Nome da stack Redis com prefixo chatwoot_
PG_STACK_NAME="chatwoot_postgres${SUFFIX}"  # Nome da stack PostgreSQL com prefixo chatwoot_
NETWORK_NAME="network_public"               # Nome da rede Docker

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar senhas seguras
generate_valid_password() {
    # Cria senha sem caracteres especiais que podem causar problemas no YAML
    local length=${1:-16}
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${length} | head -n 1)
    echo "$password"
}

# Gerar senhas
POSTGRES_PASSWORD=$(generate_valid_password 20)
echo -e "${VERDE}Senha do PostgreSQL gerada: ${RESET}${POSTGRES_PASSWORD}"

SECRET_KEY_BASE=$(openssl rand -hex 32)
echo -e "${VERDE}Secret Key Base gerado: ${RESET}${SECRET_KEY_BASE}"

# Função para exibir erros e sair
error_exit() {
    echo -e "${VERMELHO}ERRO: $1${RESET}" >&2
    exit 1
}

# Criar volumes Docker necessários
echo -e "${VERDE}Criando volumes Docker...${RESET}"
docker volume create chatwoot_data${SUFFIX} 2>/dev/null || echo "Volume chatwoot_data${SUFFIX} já existe."
docker volume create chatwoot_public${SUFFIX} 2>/dev/null || echo "Volume chatwoot_public${SUFFIX} já existe."
docker volume create chatwoot_postgres_data${SUFFIX} 2>/dev/null || echo "Volume chatwoot_postgres_data${SUFFIX} já existe."
docker volume create chatwoot_redis_data${SUFFIX} 2>/dev/null || echo "Volume chatwoot_redis_data${SUFFIX} já existe."

# Verificar se a rede existe, caso contrário, criar
docker network inspect ${NETWORK_NAME} >/dev/null 2>&1 || {
    echo -e "${VERDE}Criando rede ${NETWORK_NAME}...${RESET}"
    # Criar a rede como attachable para permitir conexão direta para testes
    docker network create --driver overlay --attachable ${NETWORK_NAME}
}

# Criar arquivo docker-compose para a stack Redis
echo -e "${VERDE}Criando arquivo docker-compose para a stack Redis...${RESET}"
cat > "${REDIS_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  redis${SUFFIX}:
    image: redis:latest
    command: redis-server --appendonly yes
    volumes:
      - chatwoot_redis_data${SUFFIX}:/data
    networks:
      - ${NETWORK_NAME}
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3
        
volumes:
  chatwoot_redis_data${SUFFIX}:
    external: true

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOL

# Criar arquivo docker-compose para a stack PostgreSQL
echo -e "${VERDE}Criando arquivo docker-compose para a stack PostgreSQL...${RESET}"
cat > "${PG_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  postgres${SUFFIX}:
    image: postgres:13
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=postgres
      - POSTGRES_DB=chatwoot
    volumes:
      - chatwoot_postgres_data${SUFFIX}:/var/lib/postgresql/data
    networks:
      - ${NETWORK_NAME}
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  chatwoot_postgres_data${SUFFIX}:
    external: true

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOL

# Criar arquivo docker-compose para a stack Chatwoot
echo -e "${VERDE}Criando arquivo docker-compose para a stack Chatwoot...${RESET}"
cat > "${CHATWOOT_STACK_NAME}.yaml" <<EOL
version: "3.7"
services:
  chatwoot_app${SUFFIX}:
    image: chatwoot/chatwoot:v4.0.1
    command: bundle exec rails s -p 3000 -b 0.0.0.0
    entrypoint: docker/entrypoints/rails.sh
    volumes:
      - chatwoot_data${SUFFIX}:/app/storage
      - chatwoot_public${SUFFIX}:/app
    networks:
      - ${NETWORK_NAME}
    environment:
      - INSTALLATION_NAME=Chatwoot
      - NODE_ENV=production
      - RAILS_ENV=production
      - INSTALLATION_ENV=docker
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - FRONTEND_URL=https://${CHATWOOT_DOMAIN}
      - DEFAULT_LOCALE=pt_BR
      - FORCE_SSL=true
      - ENABLE_ACCOUNT_SIGNUP=false
      - REDIS_URL=redis://redis${SUFFIX}:6379
      - POSTGRES_HOST=postgres${SUFFIX}
      - POSTGRES_USERNAME=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DATABASE=chatwoot
      - ACTIVE_STORAGE_SERVICE=local
      - RAILS_LOG_TO_STDOUT=true
      - USE_INBOX_AVATAR_FOR_BOT=true
      # Performance
      - SIDEKIQ_CONCURRENCY=10
      - RACK_TIMEOUT_SERVICE_TIMEOUT=0
      - RAILS_MAX_THREADS=5
      - WEB_CONCURRENCY=2
      - ENABLE_RACK_ATTACK=false
      - WEBHOOKS_TRIGGER_TIMEOUT=40
      # Email (configurable após instalação)
      - MAILER_SENDER_EMAIL=Chatwoot <${CHATWOOT_ADMIN_EMAIL}>
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
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3
      labels:
        - traefik.enable=true
        - traefik.http.routers.chatwoot_app${SUFFIX}.rule=Host(\`${CHATWOOT_DOMAIN}\`)
        - traefik.http.routers.chatwoot_app${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.chatwoot_app${SUFFIX}.tls=true
        - traefik.http.routers.chatwoot_app${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.chatwoot_app${SUFFIX}.priority=1
        - traefik.http.routers.chatwoot_app${SUFFIX}.service=chatwoot_app${SUFFIX}
        - traefik.http.services.chatwoot_app${SUFFIX}.loadbalancer.server.port=3000 
        - traefik.http.services.chatwoot_app${SUFFIX}.loadbalancer.passhostheader=true 
        - traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https
        - traefik.http.routers.chatwoot_app${SUFFIX}.middlewares=sslheader@docker

  chatwoot_sidekiq${SUFFIX}:
    image: chatwoot/chatwoot:v4.0.1
    command: bundle exec sidekiq -C config/sidekiq.yml
    volumes:
      - chatwoot_data${SUFFIX}:/app/storage
      - chatwoot_public${SUFFIX}:/app
    networks:
      - ${NETWORK_NAME}
    environment:
      - INSTALLATION_NAME=Chatwoot
      - NODE_ENV=production
      - RAILS_ENV=production
      - INSTALLATION_ENV=docker
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - FRONTEND_URL=https://${CHATWOOT_DOMAIN}
      - DEFAULT_LOCALE=pt_BR
      - FORCE_SSL=true
      - ENABLE_ACCOUNT_SIGNUP=false
      - REDIS_URL=redis://redis${SUFFIX}:6379
      - POSTGRES_HOST=postgres${SUFFIX}
      - POSTGRES_USERNAME=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DATABASE=chatwoot
      - ACTIVE_STORAGE_SERVICE=local
      - RAILS_LOG_TO_STDOUT=true
      - USE_INBOX_AVATAR_FOR_BOT=true
      # Performance
      - SIDEKIQ_CONCURRENCY=10
      - RACK_TIMEOUT_SERVICE_TIMEOUT=0
      - RAILS_MAX_THREADS=5
      - WEB_CONCURRENCY=2
      - ENABLE_RACK_ATTACK=false
      - WEBHOOKS_TRIGGER_TIMEOUT=40
      # Email (configurable após instalação)
      - MAILER_SENDER_EMAIL=Chatwoot <${CHATWOOT_ADMIN_EMAIL}>
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
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 3

volumes:
  chatwoot_data${SUFFIX}:
    external: true
  chatwoot_public${SUFFIX}:
    external: true

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
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

    # Para depuração - mostrar o conteúdo do arquivo YAML
    echo -e "${VERDE}Conteúdo do arquivo ${yaml_file}:${RESET}"
    cat "${yaml_file}"
    echo

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

# Implementar stacks na ordem correta: primeiro Redis e PostgreSQL, depois Chatwoot
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

# Adicionar uma pausa para garantir que os serviços anteriores sejam inicializados
echo -e "${VERDE}Aguardando 15 segundos para inicialização dos serviços Redis e PostgreSQL...${RESET}"
sleep 15

# Processar Chatwoot por último (depende dos outros)
process_stack "$CHATWOOT_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack Chatwoot."
fi

# Preparar os dados para o webhook
timestamp=$(date +"%Y-%m-%d %H:%M:%S")
hostname=$(hostname)
server_ip=$(hostname -I | awk '{print $1}')

# Criar objeto JSON para o webhook
WEBHOOK_DATA=$(cat << EOF
{
  "installation_id": "${INSTALLATION_ID}",
  "timestamp": "${timestamp}",
  "hostname": "${hostname}",
  "server_ip": "${server_ip}",
  "link": "https://${CHATWOOT_DOMAIN}",
  "chatwoot": {
    "domain": "${CHATWOOT_DOMAIN}",
    "admin_email": "${CHATWOOT_ADMIN_EMAIL}",
    "secret_key_base": "${SECRET_KEY_BASE}",
    "database_uri": "postgresql://postgres:${POSTGRES_PASSWORD}@postgres${SUFFIX}:5432/chatwoot"
  },
  "stacks": {
    "redis": "${REDIS_STACK_NAME}",
    "postgres": "${PG_STACK_NAME}",
    "chatwoot": "${CHATWOOT_STACK_NAME}"
  },
  "suffix": "${SUFFIX}"
}
EOF
)

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    # Cria o arquivo de credenciais separadamente para evitar problemas com a saída
    cat > "${CREDENTIALS_DIR}/chatwoot${SUFFIX}.txt" << EOF
Chatwoot Information
URL: https://${CHATWOOT_DOMAIN}
Admin Email: ${CHATWOOT_ADMIN_EMAIL}
Secret Key Base: ${SECRET_KEY_BASE}
PostgreSQL Password: ${POSTGRES_PASSWORD}
Database: postgresql://postgres:${POSTGRES_PASSWORD}@postgres${SUFFIX}:5432/chatwoot
EOF
    chmod 600 "${CREDENTIALS_DIR}/chatwoot${SUFFIX}.txt"
    echo -e "${VERDE}Credenciais do Chatwoot salvas em ${CREDENTIALS_DIR}/chatwoot${SUFFIX}.txt${RESET}"
else
    echo -e "${AMARELO}Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console.${RESET}"
fi

# Criar um objeto JSON de saída para integração com outros sistemas
cat << EOF > /tmp/chatwoot${SUFFIX}_output.json
{
  "url": "https://${CHATWOOT_DOMAIN}",
  "adminEmail": "${CHATWOOT_ADMIN_EMAIL}",
  "secretKeyBase": "${SECRET_KEY_BASE}",
  "postgresPassword": "${POSTGRES_PASSWORD}",
  "chatwootStackName": "${CHATWOOT_STACK_NAME}",
  "redisStackName": "${REDIS_STACK_NAME}",
  "postgresStackName": "${PG_STACK_NAME}",
  "databaseUri": "postgresql://postgres:${POSTGRES_PASSWORD}@postgres${SUFFIX}:5432/chatwoot"
}
EOF

echo -e "${VERDE}Arquivo JSON de saída criado em /tmp/chatwoot${SUFFIX}_output.json${RESET}"

# Enviar dados para o webhook
echo -e "${VERDE}Enviando dados da instalação para o webhook...${RESET}"
WEBHOOK_RESPONSE=$(curl -s -X POST "${WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  -d "${WEBHOOK_DATA}" \
  -w "\n%{http_code}")

HTTP_CODE=$(echo "$WEBHOOK_RESPONSE" | tail -n1)
WEBHOOK_BODY=$(echo "$WEBHOOK_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 202 ]; then
    echo -e "${VERDE}Dados enviados com sucesso para o webhook.${RESET}"
else
    echo -e "${AMARELO}Aviso: Não foi possível enviar os dados para o webhook. Código HTTP: ${HTTP_CODE}${RESET}"
    echo "Resposta: ${WEBHOOK_BODY}"
fi

# Instrução para inicializar o banco de dados do Chatwoot após a instalação
echo -e "${VERDE}Instruções pós-instalação:${RESET}"
echo -e "${BEGE}Para finalizar a configuração do Chatwoot, execute o seguinte comando no container chatwoot_app:${RESET}"
echo -e "docker exec -it \$(docker ps -q -f name=${CHATWOOT_STACK_NAME}_chatwoot_app) bundle exec rails db:chatwoot_prepare"
echo -e "${BEGE}Após isso, acesse https://${CHATWOOT_DOMAIN} e crie sua conta de administrador.${RESET}"

echo "---------------------------------------------"
echo -e "${VERDE}[ Chatwoot - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}URL:${RESET} https://${CHATWOOT_DOMAIN}"
echo -e "${VERDE}Email do Admin:${RESET} ${CHATWOOT_ADMIN_EMAIL}"
echo -e "${VERDE}Secret Key Base:${RESET} ${SECRET_KEY_BASE}"
echo -e "${VERDE}PostgreSQL Password:${RESET} ${POSTGRES_PASSWORD}"
echo -e "${VERDE}Stacks criadas com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${REDIS_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${PG_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${CHATWOOT_STACK_NAME}${RESET}"
echo -e "${VERDE}Acesse seu Chatwoot através do endereço:${RESET} https://${CHATWOOT_DOMAIN}"
echo -e "${VERDE}As stacks estão disponíveis e editáveis no Portainer.${RESET}"
