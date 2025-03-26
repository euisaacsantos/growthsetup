#!/bin/bash
# Script para formatar partições e reinstalar o Ubuntu 20.04 sem interação do usuário
# AVISO: Este script apagará TODOS os dados do disco selecionado
# Execute como root (sudo)

# Configurações - ALTERE ESTAS VARIÁVEIS CONFORME NECESSÁRIO
TARGET_DISK="sda"  # Disco a ser formatado (ex: sda, vda, nvme0n1)
HOSTNAME="ubuntu-server"  # Nome do servidor
USERNAME="ubuntu"  # Nome do usuário a ser criado
PASSWORD="ubuntu"  # Senha do usuário
TIMEZONE="America/Sao_Paulo"  # Fuso horário

# Verificar se está executando como root
if [ "$EUID" -ne 0 ]; then
  echo "Este script precisa ser executado como root (use sudo)"
  exit 1
fi

# Função para exibir mensagens com formatação
print_msg() {
  echo -e "\n\033[1;34m>>> $1\033[0m\n"
}

clear
echo "====================================================="
echo "    SCRIPT DE FORMATAÇÃO E REINSTALAÇÃO DO UBUNTU    "
echo "====================================================="
echo ""
echo "Disco alvo: /dev/$TARGET_DISK"
echo "Hostname: $HOSTNAME"
echo "Usuário: $USERNAME"
echo ""

# Verificar se o disco existe
if ! lsblk | grep -q "^$TARGET_DISK"; then
  echo "Erro: O disco $TARGET_DISK não foi encontrado!"
  exit 1
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
print_msg "Desmontando todas as partições do disco $TARGET_DISK..."
umount /dev/${TARGET_DISK}* 2>/dev/null
swapoff -a

# Zerar o início do disco (limpar tabela de partições)
print_msg "Zerando o início do disco..."
dd if=/dev/zero of=/dev/$TARGET_DISK bs=1M count=10

# Criar nova tabela de partições GPT
print_msg "Criando nova tabela de partições GPT..."
parted -s /dev/$TARGET_DISK mklabel gpt

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
parted -s /dev/$TARGET_DISK mkpart "EFI" fat32 1MiB 513MiB
parted -s /dev/$TARGET_DISK set 1 esp on
parted -s /dev/$TARGET_DISK mkpart "boot" ext4 513MiB 1537MiB
parted -s /dev/$TARGET_DISK mkpart "swap" linux-swap 1537MiB $((1537 + (swap_gb * 1024)))MiB
parted -s /dev/$TARGET_DISK mkpart "root" ext4 $((1537 + (swap_gb * 1024)))MiB 100%

# Verificar o prefixo das partições
if [[ $TARGET_DISK == nvme* ]] || [[ $TARGET_DISK == mmc* ]]; then
  part_prefix="p"
else
  part_prefix=""
fi

# Formatar as partições
print_msg "Formatando as partições..."
mkfs.fat -F32 /dev/${TARGET_DISK}${part_prefix}1
mkfs.ext4 -L boot /dev/${TARGET_DISK}${part_prefix}2
mkswap -L swap /dev/${TARGET_DISK}${part_prefix}3
mkfs.ext4 -L root /dev/${TARGET_DISK}${part_prefix}4

# Montar o sistema de arquivos para instalação
print_msg "Montando o sistema de arquivos..."
mkdir -p /mnt/ubuntu
mount /dev/${TARGET_DISK}${part_prefix}4 /mnt/ubuntu
mkdir -p /mnt/ubuntu/boot
mount /dev/${TARGET_DISK}${part_prefix}2 /mnt/ubuntu/boot
mkdir -p /mnt/ubuntu/boot/efi
mount /dev/${TARGET_DISK}${part_prefix}1 /mnt/ubuntu/boot/efi

# Instalar o sistema base (Ubuntu 20.04 Focal)
print_msg "Instalando o sistema base (Ubuntu 20.04 Focal)..."
debootstrap --arch=amd64 focal /mnt/ubuntu http://archive.ubuntu.com/ubuntu/

# Configurar o sistema básico
print_msg "Configurando o sistema básico..."

# Configurar o fstab
cat > /mnt/ubuntu/etc/fstab << EOF
# /etc/fstab
UUID=$(blkid -s UUID -o value /dev/${TARGET_DISK}${part_prefix}4) /        ext4    errors=remount-ro 0 1
UUID=$(blkid -s UUID -o value /dev/${TARGET_DISK}${part_prefix}2) /boot    ext4    defaults          0 2
UUID=$(blkid -s UUID -o value /dev/${TARGET_DISK}${part_prefix}1) /boot/efi fat32   umask=0077        0 1
UUID=$(blkid -s UUID -o value /dev/${TARGET_DISK}${part_prefix}3) none     swap    sw                0 0
EOF

# Configurar o hostname
echo "$HOSTNAME" > /mnt/ubuntu/etc/hostname

# Configurar o hosts
cat > /mnt/ubuntu/etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

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
cat > /mnt/ubuntu/chroot-setup.sh << EOF
#!/bin/bash

# Configurar timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
apt update
apt install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Instalar pacotes essenciais
apt update
DEBIAN_FRONTEND=noninteractive apt install -y linux-image-generic linux-headers-generic \\
  ubuntu-standard ubuntu-server software-properties-common \\
  networkd-dispatcher systemd-timesyncd \\
  grub-efi-amd64 efibootmgr os-prober \\
  python3 openssh-server net-tools \\
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
    # Detecta automaticamente qualquer interface de rede
    # Isso tornará o script mais portável entre diferentes sistemas
    all-en:
      match:
        name: en*
      dhcp4: true
    all-eth:
      match:
        name: eth*
      dhcp4: true
NETEOF

# Criar usuário padrão
useradd -m -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo $USERNAME

# Habilitar sudo sem senha para o usuário
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME

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
echo "O sistema Ubuntu 20.04 foi instalado no disco /dev/$TARGET_DISK"
echo "Você pode reiniciar o sistema e inicializar a partir deste disco."
echo ""
echo "Credenciais padrão:"
echo "Usuário: $USERNAME"
echo "Senha: $PASSWORD"
echo ""
echo "IMPORTANTE: Altere a senha após o primeiro login!"
echo ""

# Reiniciar automaticamente
reboot

exit 0
