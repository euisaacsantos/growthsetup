#!/bin/bash
# WordPress Diagnostic Script
# Este script ajuda a diagnosticar problemas com o WordPress em Docker Swarm

# Cores para formatação
AMARELO="\e[33m"
VERDE="\e[32m"
VERMELHO="\e[31m"
RESET="\e[0m"
BEGE="\e[97m"
AZUL="\e[36m"

# Função para imprimir cabeçalhos
print_header() {
    echo -e "${AZUL}==== $1 ====${RESET}"
}

# Solicitar o sufixo se houver
echo -e "${VERDE}Digite o sufixo do WordPress (deixe em branco se não houver):${RESET}"
read SUFFIX
if [ -n "$SUFFIX" ] && [[ ! "$SUFFIX" =~ ^_ ]]; then
    SUFFIX="_$SUFFIX"
fi

WORDPRESS_STACK_NAME="wordpress${SUFFIX}"
MYSQL_STACK_NAME="wordpress_mysql${SUFFIX}"

echo -e "${VERDE}Diagnóstico para stacks:${RESET}"
echo -e "  - WordPress: ${BEGE}${WORDPRESS_STACK_NAME}${RESET}"
echo -e "  - MySQL: ${BEGE}${MYSQL_STACK_NAME}${RESET}"
echo 

# 1. Verificar status das stacks
print_header "Verificando status das stacks Docker Swarm"
docker stack ls | grep -E "($WORDPRESS_STACK_NAME|$MYSQL_STACK_NAME)"
echo

# 2. Verificar serviços
print_header "Verificando serviços das stacks"
docker service ls | grep -E "($WORDPRESS_STACK_NAME|$MYSQL_STACK_NAME)"
echo

# 3. Verificar logs do MySQL
print_header "Últimas 20 linhas do log do MySQL"
docker service logs $MYSQL_STACK_NAME"_mysql" --tail 20 2>/dev/null || echo -e "${VERMELHO}Não foi possível obter logs do MySQL${RESET}"
echo

# 4. Verificar logs do WordPress
print_header "Últimas 20 linhas do log do WordPress"
docker service logs $WORDPRESS_STACK_NAME"_wordpress" --tail 20 2>/dev/null || echo -e "${VERMELHO}Não foi possível obter logs do WordPress${RESET}"
echo

# 5. Verificar containers em execução
print_header "Containers em execução"
docker ps | grep -E "($WORDPRESS_STACK_NAME|$MYSQL_STACK_NAME)"
echo

# 6. Testar conexão do container WordPress com MySQL
print_header "Testando conectividade do WordPress com MySQL"
WP_CONTAINER=$(docker ps -q --filter name=$WORDPRESS_STACK_NAME)
if [ -n "$WP_CONTAINER" ]; then
    echo -e "${VERDE}Container WordPress encontrado: ${BEGE}$WP_CONTAINER${RESET}"
    echo -e "${VERDE}Tentando conexão com MySQL...${RESET}"
    docker exec -i $WP_CONTAINER ping -c 2 $MYSQL_STACK_NAME"_mysql" 2>/dev/null || 
        echo -e "${VERMELHO}Falha ao executar ping para MySQL${RESET}"
else
    echo -e "${VERMELHO}Container WordPress não encontrado ou não está rodando${RESET}"
fi
echo

# 7. Verificar rede
print_header "Verificando rede GrowthNet"
docker network inspect GrowthNet | grep -E '("Name"|"EnableIPv6"|"Driver"|"Scope")'
docker network inspect GrowthNet | grep -E '("Name"|"IPv4Address")' | grep -A 1 -E "($WORDPRESS_STACK_NAME|$MYSQL_STACK_NAME)"
echo

# 8. Verificar volumes
print_header "Verificando volumes existentes"
docker volume ls | grep -E "($WORDPRESS_STACK_NAME|$MYSQL_STACK_NAME|wordpress_data$SUFFIX|wordpress_db_data$SUFFIX|wordpress_config$SUFFIX)"
echo

# 9. Verificar espaço em disco
print_header "Verificando espaço em disco"
df -h /var/lib/docker
echo

# 10. Verificar detalhes do MySQL
print_header "Detalhes do serviço MySQL"
docker service inspect $MYSQL_STACK_NAME"_mysql" --pretty
echo

# 11. Verificar detalhes do WordPress
print_header "Detalhes do serviço WordPress"
docker service inspect $WORDPRESS_STACK_NAME"_wordpress" --pretty
echo

# 12. Analisar stack yaml
print_header "Analisando o arquivo YAML do WordPress (se existir)"
if [ -f "$WORDPRESS_STACK_NAME.yaml" ]; then
    echo -e "${VERDE}Arquivo $WORDPRESS_STACK_NAME.yaml encontrado:${RESET}"
    cat "$WORDPRESS_STACK_NAME.yaml" | grep -v "password"
else
    echo -e "${VERMELHO}Arquivo $WORDPRESS_STACK_NAME.yaml não encontrado${RESET}"
fi
echo

# 13. Analisar status das tarefas Docker Swarm
print_header "Status das tarefas Docker Swarm"
docker service ps $WORDPRESS_STACK_NAME"_wordpress" --no-trunc
echo

print_header "Recomendações"
echo -e "1. ${VERDE}Se o MySQL estiver rodando, mas o WordPress não:${RESET}"
echo -e "   - Verifique se a rede GrowthNet está funcionando corretamente"
echo -e "   - Tente recriar apenas a stack do WordPress: ${BEGE}docker stack rm $WORDPRESS_STACK_NAME && docker stack deploy -c $WORDPRESS_STACK_NAME.yaml $WORDPRESS_STACK_NAME${RESET}"
echo
echo -e "2. ${VERDE}Se ambos não estiverem rodando:${RESET}"
echo -e "   - Verifique se há erros nos logs dos serviços"
echo -e "   - Certifique-se de que os volumes estão criados corretamente"
echo -e "   - Tente limpar tudo e reinstalar: ${BEGE}docker stack rm $WORDPRESS_STACK_NAME $MYSQL_STACK_NAME${RESET}"
echo
echo -e "3. ${VERDE}Para visualizar logs completos:${RESET}"
echo -e "   - WordPress: ${BEGE}docker service logs $WORDPRESS_STACK_NAME"_wordpress" --follow${RESET}"
echo -e "   - MySQL: ${BEGE}docker service logs $MYSQL_STACK_NAME"_mysql" --follow${RESET}"
