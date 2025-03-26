#!/bin/bash
# Script para criar stack editável no Portainer com chave API aleatória

# Gerar uma chave API aleatória
API_KEY=$(openssl rand -hex 16)
echo "Chave API gerada: $API_KEY"

# Gerar arquivo docker-compose
cat > ./docker-compose.yml << EOF
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

# Criar volumes
docker volume create redis_data
docker volume create postgres_data
docker volume create evolution_instances

# Criar rede
docker network create --driver overlay GrowthNet 2>/dev/null || echo "Rede GrowthNet já existe."

# Criar arquivo de stack no diretório do Portainer
STACK_DIR="/opt/portainer/data/compose/evolution-stack"
mkdir -p "$STACK_DIR"
cp ./docker-compose.yml "$STACK_DIR/docker-compose.yml"

# Criar arquivo de metadados do stack
cat > "$STACK_DIR/stack.json" << EOF
{
  "Name": "evolution-stack",
  "Type": 1,
  "SwarmID": "default",
  "EntryPoint": "docker-compose.yml"
}
EOF

# Reiniciar o Portainer para que ele reconheça o novo stack
docker service update --force portainer

# Salvar credenciais
mkdir -p /root/.credentials
chmod 700 /root/.credentials

cat > /root/.credentials/evolution.txt << EOF
Evolution API Information
URL: https://api.trafegocomia.com
API Key: ${API_KEY}
Database: postgresql://postgres:b2ecbaa44551df03fa3793b38091cff7@postgres:5432/evolution
EOF
chmod 600 /root/.credentials/evolution.txt

echo "Stack evolution-stack criado com sucesso!"
echo "O stack aparecerá no Portainer após a reinicialização do serviço."
echo "Credenciais da Evolution API salvas em /root/.credentials/evolution.txt"
echo "API Key: $API_KEY"
