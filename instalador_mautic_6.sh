#!/bin/bash
# Script para criar stacks para Mautic 6 no Portainer (Mautic e MySQL)
# Uso: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_mautic6.sh | bash -s <portainer_url> <mautic_domain> <portainer_password> <mautic_admin_email> [sufixo] [id-xxxx]
# Exemplo: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_mautic6.sh | bash -s painel.trafegocomia.com mautic.growthtap.com.br senha123 admin@exemplo.com cliente1 id-12341221125

# Verificar parâmetros obrigatórios
if [ $# -lt 4 ]; then
    echo "Uso: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_mautic6.sh | bash -s <portainer_url> <mautic_domain> <portainer_password> <mautic_admin_email> [sufixo] [id-xxxx]"
    echo "Exemplo: curl -s -k https://raw.githubusercontent.com/euisaacsantos/growthsetup/refs/heads/main/instalador_mautic6.sh | bash -s painel.trafegocomia.com mautic.growthtap.com.br senha123 admin@exemplo.com cliente1 id-12341221125"
    exit 1
fi

# Capturar parâmetros da linha de comando
PORTAINER_URL="https://$1"           # URL do Portainer
MAUTIC_DOMAIN="$2"                   # Domínio para o Mautic
PORTAINER_PASSWORD="$3"              # Senha do Portainer
MAUTIC_ADMIN_EMAIL="$4"              # Email do administrador do Mautic

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
PORTAINER_USER="admin"                   # Usuário do Portainer
MAUTIC_STACK_NAME="mautic${SUFFIX}"      # Nome da stack Mautic
MYSQL_STACK_NAME="mautic_mysql${SUFFIX}" # Nome da stack MySQL

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"

# Gerar senhas seguras sem caracteres especiais que podem causar problemas no YAML
generate_valid_password() {
    local length=${1:-16}
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${length} | head -n 1)
    echo "$password"
}

# Gerar senhas para MySQL e Mautic
MYSQL_ROOT_PASSWORD=$(generate_valid_password 20)
echo -e "${VERDE}Senha do MySQL Root gerada: ${RESET}${MYSQL_ROOT_PASSWORD}"

MYSQL_PASSWORD=$(generate_valid_password 20)
echo -e "${VERDE}Senha do usuário MySQL do Mautic gerada: ${RESET}${MYSQL_PASSWORD}"

MAUTIC_ADMIN_PASSWORD=$(generate_valid_password 16)
echo -e "${VERDE}Senha do admin do Mautic gerada: ${RESET}${MAUTIC_ADMIN_PASSWORD}"

# Gerar chave secreta para o Mautic
MAUTIC_SECRET_KEY=$(generate_valid_password 32)
echo -e "${VERDE}Chave secreta do Mautic gerada: ${RESET}${MAUTIC_SECRET_KEY}"

# Função para exibir erros e sair
error_exit() {
    echo -e "${VERMELHO}ERRO: $1${RESET}" >&2
    exit 1
}

# Criar volumes Docker necessários
echo -e "${VERDE}Criando volumes Docker...${RESET}"
docker volume create mautic_data${SUFFIX} 2>/dev/null || echo "Volume mautic_data${SUFFIX} já existe."
docker volume create mautic_config${SUFFIX} 2>/dev/null || echo "Volume mautic_config${SUFFIX} já existe."
docker volume create mautic_plugins${SUFFIX} 2>/dev/null || echo "Volume mautic_plugins${SUFFIX} já existe."
docker volume create mautic_media${SUFFIX} 2>/dev/null || echo "Volume mautic_media${SUFFIX} já existe."
docker volume create mautic_themes${SUFFIX} 2>/dev/null || echo "Volume mautic_themes${SUFFIX} já existe."
docker volume create mautic_translations${SUFFIX} 2>/dev/null || echo "Volume mautic_translations${SUFFIX} já existe."
docker volume create mautic_db_data${SUFFIX} 2>/dev/null || echo "Volume mautic_db_data${SUFFIX} já existe."

# Verificar se a rede GrowthNet existe, caso contrário, criar
docker network inspect GrowthNet >/dev/null 2>&1 || {
    echo -e "${VERDE}Criando rede GrowthNet...${RESET}"
    # Criar a rede como attachable para permitir conexão direta para testes
    docker network create --driver overlay --attachable GrowthNet
}

# Criar arquivo docker-compose para a stack MySQL
echo -e "${VERDE}Criando arquivo docker-compose para a stack MySQL...${RESET}"
cat > "${MYSQL_STACK_NAME}.yaml" <<EOL
version: '3.7'
services:
  mysql:
    image: mysql:8.0
    command: --default-authentication-plugin=mysql_native_password
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=mautic
      - MYSQL_USER=mautic
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - TZ=America/Sao_Paulo
    volumes:
      - mautic_db_data${SUFFIX}:/var/lib/mysql
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
  mautic_db_data${SUFFIX}:
    external: true

networks:
  GrowthNet:
    external: true
    name: GrowthNet
EOL

# Criar arquivo docker-compose para a stack Mautic 6 usando imagem com Composer
echo -e "${VERDE}Criando arquivo docker-compose para a stack Mautic 6...${RESET}"
cat > "${MAUTIC_STACK_NAME}.yaml" <<EOL
version: "3.7"
services:
  mautic:
    image: mautic/mautic:v6-apache
    networks:
      - GrowthNet
    environment:
      - MAUTIC_DB_HOST=${MYSQL_STACK_NAME}_mysql
      - MAUTIC_DB_USER=mautic
      - MAUTIC_DB_PASSWORD=${MYSQL_PASSWORD}
      - MAUTIC_DB_NAME=mautic
      - MAUTIC_DB_PORT=3306
      - MAUTIC_DB_TABLE_PREFIX=mautic_
      - MAUTIC_RUN_CRON_JOBS=true
      - PHP_MEMORY_LIMIT=512M
      - MAUTIC_ADMIN_EMAIL=${MAUTIC_ADMIN_EMAIL}
      - MAUTIC_ADMIN_PASSWORD=${MAUTIC_ADMIN_PASSWORD}
      - MAUTIC_ADMIN_USERNAME=admin
      - MAUTIC_SECRET_KEY=${MAUTIC_SECRET_KEY}
      - TZ=America/Sao_Paulo
    volumes:
      - mautic_data${SUFFIX}:/var/www/html
      - mautic_config${SUFFIX}:/var/www/html/docroot/app/config
      - mautic_plugins${SUFFIX}:/var/www/html/docroot/plugins
      - mautic_media${SUFFIX}:/var/www/html/docroot/media
      - mautic_themes${SUFFIX}:/var/www/html/docroot/themes
      - mautic_translations${SUFFIX}:/var/www/html/docroot/translations
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
        - "traefik.http.routers.mautic${SUFFIX}.rule=Host(\`${MAUTIC_DOMAIN}\`)"
        - traefik.http.routers.mautic${SUFFIX}.entrypoints=websecure
        - traefik.http.routers.mautic${SUFFIX}.tls=true
        - traefik.http.routers.mautic${SUFFIX}.tls.certresolver=letsencryptresolver
        - traefik.http.routers.mautic${SUFFIX}.priority=1
        - traefik.http.routers.mautic${SUFFIX}.service=mautic${SUFFIX}
        - traefik.http.services.mautic${SUFFIX}.loadbalancer.server.port=80
        - traefik.http.services.mautic${SUFFIX}.loadbalancer.passHostHeader=1

volumes:
  mautic_data${SUFFIX}:
    external: true
  mautic_config${SUFFIX}:
    external: true
  mautic_plugins${SUFFIX}:
    external: true
  mautic_media${SUFFIX}:
    external: true
  mautic_themes${SUFFIX}:
    external: true
  mautic_translations${SUFFIX}:
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

# Implementar stacks na ordem correta: primeiro MySQL, depois Mautic
echo -e "${VERDE}Iniciando deploy das stacks em sequência...${RESET}"

# Processar MySQL primeiro
process_stack "$MYSQL_STACK_NAME"
if [ $? -ne 0 ]; then
    echo -e "${AMARELO}Aviso: Problemas ao implementar MySQL, mas continuando...${RESET}"
fi

# Adicionar uma pausa para garantir que o MySQL seja inicializado
echo -e "${VERDE}Aguardando 15 segundos para inicialização do MySQL...${RESET}"
sleep 15

# Processar Mautic segundo (depende do MySQL)
process_stack "$MAUTIC_STACK_NAME"
if [ $? -ne 0 ]; then
    error_exit "Falha ao implementar a stack Mautic."
fi

# Forçar download da nova imagem para garantir versão mais recente
echo -e "${VERDE}Garantindo o download da versão mais recente do Mautic 6...${RESET}"
docker pull mautic/mautic:v6-apache

# Processar Mautic novamente para garantir que a nova imagem seja usada
echo -e "${VERDE}Atualizando a stack Mautic com a versão 6...${RESET}"
docker service update --force ${MAUTIC_STACK_NAME}_mautic

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
  "link": "https://${MAUTIC_DOMAIN}",
  "mautic": {
    "domain": "${MAUTIC_DOMAIN}",
    "admin_email": "${MAUTIC_ADMIN_EMAIL}",
    "admin_password": "${MAUTIC_ADMIN_PASSWORD}",
    "database_uri": "mysql://mautic:${MYSQL_PASSWORD}@${MYSQL_STACK_NAME}_mysql:3306/mautic",
    "version": "6.0"
  },
  "stacks": {
    "mysql": "${MYSQL_STACK_NAME}",
    "mautic": "${MAUTIC_STACK_NAME}"
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
    cat > "${CREDENTIALS_DIR}/mautic${SUFFIX}.txt" << EOF
Mautic 6 Information
URL: https://${MAUTIC_DOMAIN}
Email do Admin: ${MAUTIC_ADMIN_EMAIL}
Senha do Admin: ${MAUTIC_ADMIN_PASSWORD}
MySQL Root Password: ${MYSQL_ROOT_PASSWORD}
MySQL Mautic Password: ${MYSQL_PASSWORD}
Mautic Secret Key: ${MAUTIC_SECRET_KEY}
Database: mysql://mautic:${MYSQL_PASSWORD}@${MYSQL_STACK_NAME}_mysql:3306/mautic
EOF
    chmod 600 "${CREDENTIALS_DIR}/mautic${SUFFIX}.txt"
    echo -e "${VERDE}Credenciais do Mautic salvas em ${CREDENTIALS_DIR}/mautic${SUFFIX}.txt${RESET}"
else
    echo -e "${AMARELO}Não foi possível criar o diretório de credenciais. As credenciais serão exibidas apenas no console.${RESET}"
fi

# Criar um objeto JSON de saída para integração com outros sistemas
cat << EOF > /tmp/mautic${SUFFIX}_output.json
{
  "url": "https://${MAUTIC_DOMAIN}",
  "adminEmail": "${MAUTIC_ADMIN_EMAIL}",
  "adminPassword": "${MAUTIC_ADMIN_PASSWORD}",
  "mysqlRootPassword": "${MYSQL_ROOT_PASSWORD}",
  "mysqlMauticPassword": "${MYSQL_PASSWORD}",
  "mauticStackName": "${MAUTIC_STACK_NAME}",
  "mysqlStackName": "${MYSQL_STACK_NAME}",
  "databaseUri": "mysql://mautic:${MYSQL_PASSWORD}@${MYSQL_STACK_NAME}_mysql:3306/mautic",
  "version": "6.0"
}
EOF

echo -e "${VERDE}Arquivo JSON de saída criado em /tmp/mautic${SUFFIX}_output.json${RESET}"

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
echo -e "${VERDE}[ Mautic 6 - INSTALAÇÃO COMPLETA ]${RESET}"
echo -e "${VERDE}URL:${RESET} https://${MAUTIC_DOMAIN}"
echo -e "${VERDE}Email do Admin:${RESET} ${MAUTIC_ADMIN_EMAIL}"
echo -e "${VERDE}Senha do Admin:${RESET} ${MAUTIC_ADMIN_PASSWORD}"
echo -e "${VERDE}MySQL Root Password:${RESET} ${MYSQL_ROOT_PASSWORD}"
echo -e "${VERDE}MySQL Mautic Password:${RESET} ${MYSQL_PASSWORD}"
echo -e "${VERDE}Stacks criadas com sucesso via API do Portainer:${RESET}"
echo -e "  - ${BEGE}${MYSQL_STACK_NAME}${RESET}"
echo -e "  - ${BEGE}${MAUTIC_STACK_NAME}${RESET}"
echo -e "${VERDE}Acesse seu Mautic 6 através do endereço:${RESET} https://${MAUTIC_DOMAIN}"
echo -e "${VERDE}As stacks estão disponíveis e editáveis no Portainer.${RESET}"

echo -e "\n${VERDE}============== IMPORTANTE ==============\n${RESET}"
echo -e "${BEGE}Este instalador configurou o Mautic 6, que utiliza o Composer como método de instalação padrão.${RESET}"
echo -e "${BEGE}Se você encontrar problemas durante a instalação inicial:${RESET}"
echo -e "1. Acesse o container do Mautic: docker exec -it \$(docker ps -q -f name=${MAUTIC_STACK_NAME}_mautic) bash"
echo -e "2. Dentro do container, verifique a estrutura: ls -la /var/www/html"
echo -e "3. Se necessário, execute: php /var/www/html/docroot/app/console cache:clear"
echo -e "\n${VERDE}============== IMPORTANTE ==============\n${RESET}"
