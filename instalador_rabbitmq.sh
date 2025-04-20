#!/bin/bash
# Script para criar stack para RabbitMQ no Portainer
# Uso: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_rabbitmq.sh | bash -s <portainer_url> <rabbitmq_domain> <portainer_password> <rabbitmq_admin_email> [sufixo] [id-xxxx]
# Exemplo: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_rabbitmq.sh | bash -s painel.trafegocomia.com rabbitmq.growthtap.com.br senha123 admin@exemplo.com cliente1 id-12341221125

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    echo "Uso: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_rabbitmq.sh | bash -s <portainer_url> <rabbitmq_domain> <portainer_password> <rabbitmq_admin_email> [sufixo] [id-xxxx]"
    echo "Exemplo: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_rabbitmq.sh | bash -s painel.trafegocomia.com rabbitmq.growthtap.com.br senha123 admin@exemplo.com cliente1 id-12341221125"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
RABBITMQ_DOMAIN="$2"                 # Domínio para o RabbitMQ
PORTAINER_PASSWORD="$3"              # Senha do Portainer
RABBITMQ_ADMIN_EMAIL="$4"            # Email do administrador do RabbitMQ

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
PORTAINER_USER="admin"                     # Usuário do Portainer
RABBITMQ_STACK_NAME="rabbitmq${SUFFIX}"    # Nome da stack RabbitMQ

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar senhas seguras - sem caracteres especiais que podem causar problemas no YAML
generate_valid_password() {
    # Cria senha sem caracteres especiais que podem causar problemas no YAML
    local length=${1:-16}
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${length} | head -n 1)
    echo "$password"
}

# Gerar senha para RabbitMQ
RABBITMQ_ADMIN_PASSWORD=$(generate_valid_password 20)
echo -e "${VERDE}Senha do Admin do RabbitMQ gerada: ${RESET}${RABBITMQ_ADMIN_PASSWORD}"

RABBITMQ_DEFAULT_USER="admin"
echo -e "${VERDE}Usuário do RabbitMQ: ${RESET}${RABBITMQ_DEFAULT_USER}"

# Função para exibir erros e sair
error_exit() {
    echo -e "${VERMELHO}ERRO: $1${RESET}" >&2
    exit 1
}

# Criar volumes Docker necessários
echo -e "${VERDE}Criando volumes Docker...${RESET}"
docker volume create rabbitmq_data${SUFFIX} 2>/dev/null || echo "Volume rabbitmq_data${SUFFIX} já existe."

# Verificar se a rede GrowthNet existe, caso contrário, criar
docker network inspect GrowthNet >/dev/null 2>&1 || {
    echo -e "${VERDE}Criando rede GrowthNet...${RESET}"
    # Criar a rede como attachable para permitir conexão direta para testes
    docker network create --driver overlay --attachable GrowthNet
}

# Criar arquivo docker-compose para a stack RabbitMQ
echo -e "${VERDE}Criando arquivo docker-compose para a stack RabbitMQ...${RESET}"
cat > "${RABBITMQ_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  rabbitmq:
    image: rabbitmq:3.12-management
    hostname: rabbitmq-server
    ports:
      - 15672:15672  # Interface de gerenciamento
      - 5672:5672    # Conexão AMQP
    environment:
      - RABBITMQ_DEFAULT_USER=${RABBITMQ_DEFAULT_USER}
      - RABBITMQ_DEFAULT_PASS=${RABBITMQ_ADMIN_PASSWORD}
      - RABBITMQ_ERLANG_COOKIE=SWQOKODSQALRPCLNMEQG
      - TZ=America/Sao_Paulo
    volumes:
      - rabbitmq_data${SUFFIX}:/var/lib/rabbitmq
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
      labels:
        - traefik.enable=true
        - traefik.docker.network=GrowthNet
        - "traefik.http.routers.rabbitmq${SUFFIX}.rule=Host(\`${RABBITMQ_DOMAIN}\`)"
        - traefik.http.routers.rabbitmq${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.rabbitmq${SUFFIX}.tls=true
        - traefik.http.routers.rabbitmq${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.rabbitmq${SUFFIX}.priority=1
        - traefik.http.routers.rabbitmq${SUFFIX}.service=rabbitmq${SUFFIX}
        - traefik.http.services.rabbitmq${SUFFIX}.loadbalancer.server.port=15672
        - traefik.http.services.rabbitmq${SUFFIX}.loadbalancer.passHostHeader=1

volumes:
  rabbitmq_data${SUFFIX}:
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

    # Para depuração - mostrar o conteúdo do arquivo YAML
    echo -e "${VERDE}Conteúdo do arquivo ${yaml_file}:${RESET}"
    cat "${yaml_file}"
    echo

    # Método direto via Docker Swarm
    echo -e "${VERDE}Tentando deploy direto via Docker Swarm...${RESET}"
    if docker stack deploy --prune --resolve-image always -c "${yaml_file}" "${stack_name}"; then
        echo -e "${VERDE}Deploy da stack ${BEGE}${stack_name}${RESET}${VERDE} feito com sucesso via Docker Swarm!${RESET}"
        return 0
    fi
    
    echo -e "${AMARELO}Deploy via Docker Swarm falhou, tentando via API Portainer...${RESET}"

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
            echo -e "${VERMELHO}Falha em todos os métodos de deploy da stack ${stack_name}.${RESET}"
            return 1
        fi
    fi

    # Remove os arquivos temporários
    rm -f "$erro_output" "$response_output"
}

# Implementar a stack RabbitMQ
echo -e "${VERDE}Iniciando deploy da stack RabbitMQ...${RESET}"
process_stack "$RABBITMQ_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack RabbitMQ."
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
  "link": "https://${RABBITMQ_DOMAIN}",
  "rabbitmq": {
    "domain": "${RABBITMQ_DOMAIN}",
    "admin_user": "${RABBITMQ_DEFAULT_USER}",
    "admin_password": "${RABBITMQ_ADMIN_PASSWORD}",
    "amqp_uri": "amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_ADMIN_PASSWORD}@${RABBITMQ_STACK_NAME}_rabbitmq:5672/%2F"
  },
  "stacks": {
    "rabbitmq": "${RABBITMQ_STACK_NAME}"
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
    cat > "${CREDENTIALS_DIR}/rabbitmq${SUFFIX}.txt" << EOF
RabbitMQ Information
URL: https://${RABBITMQ_DOMAIN}
Usuário Admin: ${RABBITMQ_DEFAULT_USER}
Senha do Admin: ${RABBITMQ_ADMIN_PASSWORD}
AMQP URI: amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_ADMIN_PASSWORD}@${RABBITMQ_STACK_NAME}_rabbitmq:5672/%2F
EOF
    chmod 600 "${CREDENTIALS_DIR}/rabbitmq${SUFFIX}.txt"
    echo -e "${VERDE}Credenciais do RabbitMQ salvas em ${CREDENTIALS_DIR}/rabbitmq${SUFFIX}.txt${RESET}"
else
    echo -e "${AMARELO}Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console.${RESET}"
fi

# Criar um objeto JSON de saída para integração com outros sistemas
cat << EOF > /tmp/rabbitmq${SUFFIX}_output.json
{
  "url": "https://${RABBITMQ_DOMAIN}",
  "adminUser": "${RABBITMQ_DEFAULT_USER}",
  "adminPassword": "${RABBITMQ_ADMIN_PASSWORD}",
  "rabbitmqStackName": "${RABBITMQ_STACK_NAME}",
  "amqpUri": "amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_ADMIN_PASSWORD}@${RABBITMQ_STACK_NAME}_rabbitmq:5672/%2F",
  "directUrl": "http://${server_ip}:15672"
}
EOF

echo -e "${VERDE}Arquivo JSON de saída criado em /tmp/rabbitmq${SUFFIX}_output.json${RESET}"

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

# Verificar status do RabbitMQ
echo -e "${VERDE}Verificando status do RabbitMQ...${RESET}"
docker service ps ${RABBITMQ_STACK_NAME}_rabbitmq --no-trunc

echo "---------------------------------------------"
echo -e "${VERDE}[ RabbitMQ - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}URL:${RESET} https://${RABBITMQ_DOMAIN}"
echo -e "${VERDE}URL Direta:${RESET} http://${server_ip}:15672"
echo -e "${VERDE}Credenciais de acesso ao painel:${RESET}"
echo -e "  ${VERDE}Usuário:${RESET} ${RABBITMQ_DEFAULT_USER}"
echo -e "  ${VERDE}Senha:${RESET} ${RABBITMQ_ADMIN_PASSWORD}"
echo -e "${VERDE}AMQP URI:${RESET} amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_ADMIN_PASSWORD}@${RABBITMQ_STACK_NAME}_rabbitmq:5672/%2F"
echo -e "${VERDE}Stack criada com sucesso:${RESET}"
echo -e "  - ${BEGE}${RABBITMQ_STACK_NAME}${RESET}"
echo -e "${VERDE}Acesse o painel do RabbitMQ através do endereço:${RESET} https://${RABBITMQ_DOMAIN}"
echo -e "${VERDE}Ou diretamente via:${RESET} http://${server_ip}:15672"
echo -e "${VERDE}A stack está disponível e editável no Portainer.${RESET}"

# Instruções adicionais para uso do RabbitMQ
echo -e "${VERDE}Portas padrão do RabbitMQ:${RESET}"
echo -e "  - ${BEGE}5672:${RESET} AMQP 0-9-1 e 1.0 (principal)"
echo -e "  - ${BEGE}15672:${RESET} Interface de gerenciamento HTTP (exposta diretamente)"
echo -e "  - ${BEGE}15692:${RESET} Prometheus metrics"
echo -e "${VERDE}Para conectar aplicações, use a URI:${RESET}"
echo -e "${BEGE}amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_ADMIN_PASSWORD}@${RABBITMQ_STACK_NAME}_rabbitmq:5672/%2F${RESET}"
