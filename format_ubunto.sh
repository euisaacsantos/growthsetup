#!/bin/bash
# Script para formatar partições e reinstalar o Ubuntu 20.04
# AVISO: Este script apagará TODOS os dados do disco selecionado
# Execute como root (sudo)

# Verificar se está executando como root
if [ "$EUID" -ne 0 ]; then
  echo "Este script precisa ser executado como root (use sudo)"
  exit 1
fi

# Função para exibir mensagens com formatação
print_msg() {
  echo -e "\n\033[1;34m>>> $1\033[0m\n"
}

# Função para confirmar ações perigosas
confirm() {
  read -p "$1 [s/N]: " response
  case "$response" in
    [sS]* ) return 0 ;;
    * ) return 1 ;;
  esac
}

clear
echo "====================================================="
echo "    SCRIPT DE FORMATAÇÃO E REINSTALAÇÃO DO UBUNTU    "
echo "====================================================="
echo ""
echo "ATENÇÃO: Este script irá APAGAR TODOS OS DADOS do disco selecionado"
echo "e instalar uma nova cópia do Ubuntu 20.04!"
echo ""

# Confirmar antes de continuar
if ! confirm "Tem certeza que deseja continuar?"; then
  echo "Operação cancelada pelo usuário."
  exit 0
fi

# Listar discos disponíveis
print_msg "Discos disponíveis:"
lsblk -d -o NAME,SIZE,MODEL | grep -v loop

# Solicitar o disco a ser formatado
read -p "Digite o nome do disco a ser formatado (ex: sda, vda, nvme0n1): " target_disk

# Verificar se o disco existe
if ! lsblk | grep -q "^$target_disk"; then
  echo "Erro: O disco $target_disk não foi encontrado!"
  exit 1
fi

# Confirmar a escolha do disco
if ! confirm "Você selecionou o disco $target_disk. Todos os dados serão APAGADOS. Continuar?"; then
  echo "Operação cancelada pelo usuário."
  exit 0
fi

# Verificar conexão com a internet
print_msg "Verificando conexão com a internet..."
if ! ping -c 3 archive.ubuntu.com &> /dev/null; then
  echo "Erro: Sem conexão com a internet. A conexão é necessária para baixar pacotes."
  exit 1
fi

# Instalar ferramentas necessárias
print_msg "Instalando ferramentas necessárias..."
apt update
apt install -y debootstrap gdisk parted

# Desmontar todas as partições do disco alvo
print_msg "Desmontando todas as partições do disco $target_disk..."
umount /dev/${target_disk}* 2>/dev/null

# Zerar o início do disco (limpar tabela de partições)
print_msg "Zerando o início do disco..."
dd if=/dev/zero of=/dev/$target_disk bs=1M count=10

# Criar nova tabela de partições GPT
print_msg "Criando nova tabela de partições GPT..."
parted -s /dev/$target_disk mklabel gpt

# Criar partições:
# 1. Partição EFI (512MB)
# 2. Partição boot (1GB)
# 3. Partição swap (RAM + 2GB, máximo 8GB)
# 4. Partição raiz (resto do espaço)

print_msg "Criando partições..."

# Determinar tamanho de swap baseado na RAM (RAM + 2GB, máximo 8GB)
mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_gb=$((mem_kb / 1024 / 1024))
swap_gb=$((mem_gb + 2))
[ $swap_gb -gt 8 ] && swap_gb=8

# Calcular os pontos de início/fim de cada partição
parted -s /dev/$target_disk mkpart "EFI" fat32 1MiB 513MiB
parted -s /dev/$target_disk set 1 esp on
parted -s /dev/$target_disk mkpart "boot" ext4 513MiB 1537MiB
parted -s /dev/$target_disk mkpart "swap" linux-swap 1537MiB $((1537 + (swap_gb * 1024)))MiB
parted -s /dev/$target_disk mkpart "root" ext4 $((1537 + (swap_gb * 1024)))MiB 100%

# Verificar o prefixo das partições
if [[ $target_disk == nvme* ]] || [[ $target_disk == mmc* ]]; then
  part_prefix="p"
else
  part_prefix=""
fi

# Formatar as partições
print_msg "Formatando as partições..."
mkfs.fat -F32 /dev/${target_disk}${part_prefix}1
mkfs.ext4 -L boot /dev/${target_disk}${part_prefix}2
mkswap -L swap /dev/${target_disk}${part_prefix}3
mkfs.ext4 -L root /dev/${target_disk}${part_prefix}4

# Montar o sistema de arquivos para instalação
print_msg "Montando o sistema de arquivos..."
mkdir -p /mnt/ubuntu
mount /dev/${target_disk}${part_prefix}4 /mnt/ubuntu
mkdir -p /mnt/ubuntu/boot
mount /dev/${target_disk}${part_prefix}2 /mnt/ubuntu/boot
mkdir -p /mnt/ubuntu/boot/efi
mount /dev/${target_disk}${part_prefix}1 /mnt/ubuntu/boot/efi

# Instalar o sistema base (Ubuntu 20.04 Focal)
print_msg "Instalando o sistema base (Ubuntu 20.04 Focal)..."
debootstrap --arch=amd64 focal /mnt/ubuntu http://archive.ubuntu.com/ubuntu/

# Configurar o sistema básico
print_msg "Configurando o sistema básico..."

# Configurar o fstab
cat > /mnt/ubuntu/etc/fstab << EOF
# /etc/fstab
UUID=$(blkid -s UUID -o value /dev/${target_disk}${part_prefix}4) /        ext4    errors=remount-ro 0 1
UUID=$(blkid -s UUID -o value /dev/${target_disk}${part_prefix}2) /boot    ext4    defaults          0 2
UUID=$(blkid -s UUID -o value /dev/${target_disk}${part_prefix}1) /boot/efi fat32   umask=0077        0 1
UUID=$(blkid -s UUID -o value /dev/${target_disk}${part_prefix}3) none     swap    sw                0 0
EOF

# Configurar o hostname
echo "ubuntu-server" > /mnt/ubuntu/etc/hostname

# Configurar o hosts
cat > /mnt/ubuntu/etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ubuntu-server

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# Configurar sources.list
cat > /mnt/ubuntu/etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ focal-backports main restricted universe multiverse
EOF

# Chroot e configurar o sistema
print_msg "Configurando o sistema dentro do chroot..."

# Preparar chroot
mount --bind /dev /mnt/ubuntu/dev
mount --bind /dev/pts /mnt/ubuntu/dev/pts
mount --bind /proc /mnt/ubuntu/proc
mount --bind /sys /mnt/ubuntu/sys

# Script para executar dentro do chroot
cat > /mnt/ubuntu/chroot-setup.sh << 'EOF'
#!/bin/bash

# Configurar timezone
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
apt update
apt install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Instalar pacotes essenciais
apt update
DEBIAN_FRONTEND=noninteractive apt install -y linux-image-generic linux-headers-generic \
  ubuntu-standard ubuntu-server software-properties-common \
  networkd-dispatcher systemd-timesyncd \
  grub-efi-amd64 efibootmgr os-prober \
  python3 openssh-server net-tools \
  vim curl wget htop

# Configurar o grub
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck

# Configurar a rede com Netplan
mkdir -p /etc/netplan
cat > /etc/netplan/01-netcfg.yaml << 'NETEOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    # Substitua por sua interface de rede, geralmente ens33 para VMware, enp0s3 para VirtualBox
    # ou use "eth0" para sistemas mais antigos
    ens33:
      dhcp4: true
NETEOF

# Criar usuário padrão
useradd -m -s /bin/bash ubuntu
echo "ubuntu:ubuntu" | chpasswd
usermod -aG sudo ubuntu

# Habilitar sudo sem senha para o usuário ubuntu (opcional, remova se preferir mais segurança)
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 440 /etc/sudoers.d/ubuntu

# Atualizar o sistema
apt update
apt upgrade -y
apt autoremove -y
apt clean

EOF

# Tornar o script executável e executá-lo dentro do chroot
chmod +x /mnt/ubuntu/chroot-setup.sh
chroot /mnt/ubuntu /bin/bash -c "/chroot-setup.sh"

# Limpar
rm /mnt/ubuntu/chroot-setup.sh

# Desmontar tudo
print_msg "Desmontando sistemas de arquivos..."
umount /mnt/ubuntu/boot/efi
umount /mnt/ubuntu/boot
umount /mnt/ubuntu/dev/pts
umount /mnt/ubuntu/dev
umount /mnt/ubuntu/proc
umount /mnt/ubuntu/sys
umount /mnt/ubuntu

print_msg "Instalação concluída com sucesso!"
echo ""
echo "O sistema Ubuntu 20.04 foi instalado no disco /dev/$target_disk"
echo "Você pode reiniciar o sistema e inicializar a partir deste disco."
echo ""
echo "Credenciais padrão:"
echo "Usuário: ubuntu"
echo "Senha: ubuntu"
echo ""
echo "IMPORTANTE: Altere a senha após o primeiro login!"
echo ""

# Oferecer reinicialização
if confirm "Deseja reiniciar o sistema agora?"; then
  reboot
fi

exit 0
