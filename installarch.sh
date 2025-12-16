#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Arch Linux + Hyprland (Minimal)
# ===============================

### НАСТРОЙКИ ###
DISK="/dev/nvme0n1"
EFI_PART="/dev/nvme0n1p1"
ROOT_PART="/dev/nvme0n1p5"

HOSTNAME="anc"
USERNAME="anc"
PASSWORD="hesoyam"
TIMEZONE="Europe/Kyiv"

LOG_FILE="/tmp/arch_install.log"
exec &> >(tee -a "$LOG_FILE")

# ===============================
# ПРОВЕРКИ
# ===============================

[[ $EUID -ne 0 ]] && echo "Запусти от root" && exit 1
[[ ! -d /sys/firmware/efi ]] && echo "Требуется UEFI" && exit 1

ping -c 1 archlinux.org >/dev/null || {
  echo "Нет интернета"
  exit 1
}

# ===============================
# ФОРМАТИРОВАНИЕ И МОНТИРОВАНИЕ
# ===============================

mkfs.ext4 -F "$ROOT_PART"
mount "$ROOT_PART" /mnt

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# ===============================
# УСТАНОВКА BASE
# ===============================

pacstrap /mnt \
  base \
  linux \
  linux-firmware \
  networkmanager \
  sudo \
  git \
  nano

genfstab -U /mnt >> /mnt/etc/fstab

# ===============================
# НАСТРОЙКА СИСТЕМЫ
# ===============================

arch-chroot /mnt /bin/bash <<EOF
set -e

# Часовой пояс
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Локаль
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Пользователь
useradd -m -G wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

# sudo
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Сервисы
systemctl enable NetworkManager
EOF

# ===============================
# ЗАГРУЗЧИК
# ===============================

arch-chroot /mnt pacman -S --noconfirm grub efibootmgr
arch-chroot /mnt grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=GRUB

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# ===============================
# HYPRLAND (ЧИСТЫЙ)
# ===============================

arch-chroot /mnt pacman -S --noconfirm \
  hyprland \
  kitty \
  xdg-desktop-portal-hyprland \
  xdg-desktop-portal

arch-chroot /mnt /bin/bash <<EOF
mkdir -p /home/$USERNAME/.config/hypr

cat > /home/$USERNAME/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1

\$mainMod = SUPER

bind = \$mainMod, RETURN, exec, foot
bind = \$mainMod, Q, killactive
bind = \$mainMod, M, exit
bind = \$mainMod, F, fullscreen

bindm = \$mainMod, mouse:272, movewindow
bindm = \$mainMod, mouse:273, resizewindow
HYPR

chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

# ===============================
# ГОТОВО
# ===============================

echo "================================="
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo "================================="
echo "1) umount -R /mnt"
echo "2) reboot"
echo "3) Войди и запусти: Hyprland"
echo "Лог: $LOG_FILE"
