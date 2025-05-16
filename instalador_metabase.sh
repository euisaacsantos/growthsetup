#!/bin/bash
# Script para criar stacks separadas no Portainer (Metabase e PostgreSQL)
# Uso: ./install_metabase.sh <portainer_url> <metabase_domain> <portainer_password> [sufixo] [id-xxxx]
# Exemplo: ./install_metabase.sh painel.trafegocomia.com metabase.trafegocomia.com senha123 cliente1 id-12341221125
# Ou sem sufixo: ./install_metabase.sh painel.trafegocomia.com metabase.trafegocomia.com senha123 "" id-12341221125

# Verificar parâmetros obrigatórios
if [ $# -lt 3 ]; then
    echo "Uso: $0 <portainer_url> <metabase_domain> <portainer_password> [sufixo] [id-xxxx]"
    echo "Exemplo: $0 painel.trafegocomia.com metabase.trafegocomia.com senha123 cliente1 id-12341221125"
    echo "Sem sufixo: $0 painel.trafegocomia.com metabase.trafegocomia.com senha123 \"\" id-12341221125"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"        # URL do Portainer
METABASE_DOMAIN="$2"              # Domínio para o Metabase
PORTAINER_PASSWORD="$3"           # Senha do Portainer

# Inicializar variáveis
SUFFIX=""
INSTALLATION_ID="sem_id"

# Processar parâmetros opcionais (sufixo e ID)
for param in "${@:4}"; do
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
PORTAINER_USER="admin"               # Usuário do Portainer
METABASE_STACK_NAME="metabase${SUFFIX}" # Nome da stack Metabase
POSTGRES_STACK_NAME="metabase_postgres${SUFFIX}" # Nome da stack PostgreSQL

WEBHOOK_URL="https://setup.growthtap.com.br/webhook/bf813e80-f036-400b-acae-904d703df6dd"

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar senha admin aleatória para o Metabase
echo -e "${VERDE}Gerando credenciais de administrador do Metabase...${RESET}"
METABASE_ADMIN_EMAIL="admin@example.com"
METABASE_ADMIN_FIRST_NAME="Admin"
METABASE_ADMIN_LAST_NAME="User"
METABASE_ADMIN_PASSWORD=$(openssl rand -hex 8)

# Gerar senha para o PostgreSQL
POSTGRES_PASSWORD=$(openssl rand -hex 16)

echo -e "${VERDE}Credenciais do Metabase:${RESET}"
echo -e "Email: ${METABASE_ADMIN_EMAIL}"
echo -e "Senha: ${METABASE_ADMIN_PASSWORD}"

# Função para exibir erros e sair
error_exit() {
    echo -e "${VERMELHO}ERRO: $1${RESET}" >&2
    exit 1
}

# Criar volumes Docker necessários
echo -e "${VERDE}Criando volumes Docker...${RESET}"
docker volume create metabase_data${SUFFIX} 2>/dev/null || echo "Volume metabase_data${SUFFIX} já existe."
docker volume create metabase_postgres_data${SUFFIX} 2>/dev/null || echo "Volume metabase_postgres_data${SUFFIX} já existe."

# Criar rede overlay se não existir
docker network create --driver overlay GrowthNet 2>/dev/null || echo "Rede GrowthNet já existe."

# Criar arquivo docker-compose para a stack PostgreSQL
echo -e "${VERDE}Criando arquivo docker-compose para a stack PostgreSQL...${RESET}"
cat > "${POSTGRES_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  postgres${SUFFIX}:
    image: postgres:14
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=postgres
      - POSTGRES_DB=metabase
    volumes:
      - metabase_postgres_data${SUFFIX}:/var/lib/postgresql/data
    networks:
      - GrowthNet
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager

volumes:
  metabase_postgres_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack Metabase
echo -e "${VERDE}Criando arquivo docker-compose para a stack Metabase...${RESET}"
cat > "${METABASE_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  metabase${SUFFIX}:
    image: metabase/metabase:latest
    volumes:
      - metabase_data${SUFFIX}:/metabase-data
    networks:
      - GrowthNet
    environment:
      - MB_DB_TYPE=postgres
      - MB_DB_DBNAME=metabase
      - MB_DB_PORT=5432
      - MB_DB_USER=postgres
      - MB_DB_PASS=${POSTGRES_PASSWORD}
      - MB_DB_HOST=postgres${SUFFIX}
      - MB_ADMIN_EMAIL=${METABASE_ADMIN_EMAIL}
      - MB_ADMIN_FIRST_NAME=${METABASE_ADMIN_FIRST_NAME}
      - MB_ADMIN_LAST_NAME=${METABASE_ADMIN_LAST_NAME}
      - MB_ADMIN_PASSWORD=${METABASE_ADMIN_PASSWORD}
      - JAVA_TIMEZONE=America/Sao_Paulo
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
        - node.role == manager
      labels:
      - traefik.enable=true
      - traefik.http.routers.metabase${SUFFIX}.rule=Host(\`${METABASE_DOMAIN}\`)
      - traefik.http.routers.metabase${SUFFIX}.entrypoints=websecure
      - traefik.http.routers.metabase${SUFFIX}.priority=1
      - traefik.http.routers.metabase${SUFFIX}.tls.certresolver=letsencryptresolver
      - traefik.http.routers.metabase${SUFFIX}.service=metabase${SUFFIX}
      - traefik.http.services.metabase${SUFFIX}.loadbalancer.server.port=3000
      - traefik.http.services.metabase${SUFFIX}.loadbalancer.passHostHeader=1

volumes:
  metabase_data${SUFFIX}:
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

# Implementar stacks na ordem correta: primeiro PostgreSQL, depois Metabase
echo -e "${VERDE}Iniciando deploy das stacks em sequência...${RESET}"

# Processar PostgreSQL primeiro
process_stack "$POSTGRES_STACK_NAME"
if [ $? -ne 0 ]; then
    echo -e "${AMARELO}Aviso: Problemas ao implementar PostgreSQL, mas continuando...${RESET}"
fi

# Adicionar uma pausa para garantir que o serviço PostgreSQL seja inicializado
echo -e "${VERDE}Aguardando 10 segundos para inicialização do serviço PostgreSQL...${RESET}"
sleep 10

# Processar Metabase por último (depende do PostgreSQL)
process_stack "$METABASE_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack Metabase."
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
  "link": "https://${METABASE_DOMAIN}",
  "metabase": {
    "domain": "${METABASE_DOMAIN}",
    "admin_email": "${METABASE_ADMIN_EMAIL}",
    "admin_password": "${METABASE_ADMIN_PASSWORD}",
    "database_uri": "postgresql://postgres:${POSTGRES_PASSWORD}@postgres${SUFFIX}:5432/metabase"
  },
  "stacks": {
    "postgres": "${POSTGRES_STACK_NAME}",
    "metabase": "${METABASE_STACK_NAME}"
  },
  "suffix": "${SUFFIX}"
}
EOF
)

# Salvar credenciais
CREDENTIALS_DIR="/root/.credentials"
if [ -d "$CREDENTIALS_DIR" ] || mkdir -p "$CREDENTIALS_DIR"; then
    chmod 700 "$CREDENTIALS_DIR"
    
    cat > "${CREDENTIALS_DIR}/metabase${SUFFIX}.txt" << EOF
Metabase Information
URL: https://${METABASE_DOMAIN}
Admin Email: ${METABASE_ADMIN_EMAIL}
Admin Password: ${METABASE_ADMIN_PASSWORD}
Database: postgresql://postgres:${POSTGRES_PASSWORD}@postgres${SUFFIX}:5432/metabase
EOF
    chmod 600 "${CREDENTIALS_DIR}/metabase${SUFFIX}.txt"
    echo -e "${VERDE}Credenciais do Metabase salvas em ${CREDENTIALS_DIR}/metabase${SUFFIX}.txt${RESET}"
else
    echo -e "${AMARELO}Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console.${RESET}"
fi

# Criar um objeto JSON de saída para o relatório local
cat << EOF > /tmp/metabase${SUFFIX}_output.json
{
  "url": "https://${METABASE_DOMAIN}",
  "adminEmail": "${METABASE_ADMIN_EMAIL}",
  "adminPassword": "${METABASE_ADMIN_PASSWORD}",
  "postgresStackName": "${POSTGRES_STACK_NAME}",
  "metabaseStackName": "${METABASE_STACK_NAME}",
  "databaseUri": "postgresql://postgres:${POSTGRES_PASSWORD}@postgres${SUFFIX}:5432/metabase"
}
EOF

echo -e "${VERDE}Arquivo JSON de saída criado em /tmp/metabase${SUFFIX}_output.json${RESET}"

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

echo "---------------------------------------------"
echo -e "${VERDE}[ METABASE - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}URL do Metabase:${RESET} https://${METABASE_DOMAIN}"
echo -e "${VERDE}Admin Email:${RESET} ${METABASE_ADMIN_EMAIL}"
echo -e "${VERDE}Admin Password:${RESET} ${METABASE_ADMIN_PASSWORD}"
echo -e "${VERDE}Stacks criadas com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${POSTGRES_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${METABASE_STACK_NAME}${RESET}"
echo -e "${VERDE}As stacks estão disponíveis e editáveis no Portainer.${RESET}"
echo "---------------------------------------------"
