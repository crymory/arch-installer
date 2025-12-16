#!/usr/bin/env bash
set -euo pipefail

### ======================================
### Arch Linux Hyprland Installer (Базовый)
### ======================================

# ---------------------------
# Цвета для логов
# ---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/tmp/arch_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------
# Проверка root
# ---------------------------
if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен от root!"
    exit 1
fi

# ---------------------------
# Переменные по умолчанию
# ---------------------------
DISK="/dev/nvme0n1"
ROOT_PART="/dev/nvme0n1p4"
EFI_PART="/dev/nvme0n1p1"
HOSTNAME="anc"
USERNAME="anc"
PASSWORD="hesoyam"
TIMEZONE="Europe/Kyiv"

# ---------------------------
# Проверка UEFI
# ---------------------------
check_uefi() {
    if [ ! -d /sys/firmware/efi/efivars ]; then
        log_error "Система загружена не в UEFI!"
        exit 1
    fi
}

# ---------------------------
# Подключение к Wi-Fi через iwctl
# ---------------------------
wifi_connect() {
    if ! command -v iwctl &>/dev/null; then
        log_error "iwctl не найден!"
        return
    fi
    rfkill unblock wifi 2>/dev/null || true
    DEVICE=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
    if [ -z "$DEVICE" ]; then
        log_error "Wi-Fi адаптер не найден"
        return
    fi
    echo "Доступные сети:"
    iwctl station "$DEVICE" scan
    sleep 2
    iwctl station "$DEVICE" get-networks
    read -rp "Введите имя сети (SSID): " SSID
    read -srp "Введите пароль: " PASSWORD
    echo
    echo "$PASSWORD" | iwctl --passphrase - station "$DEVICE" connect "$SSID"
    sleep 3
    if iwctl station "$DEVICE" show | grep -q "connected"; then
        log_info "Подключено к $SSID"
    else
        log_error "Не удалось подключиться"
    fi
}

# ---------------------------
# Проверка интернет
# ---------------------------
check_internet() {
    if ! ping -c 2 archlinux.org &>/dev/null; then
        log_warn "Нет подключения к интернету!"
        wifi_connect
        if ! ping -c 2 archlinux.org &>/dev/null; then
            log_error "Интернет так и не появился"
            exit 1
        fi
    fi
    log_info "Интернет OK"
}

# ---------------------------
# Форматирование и монтирование
# ---------------------------
mount_partitions() {
    mkfs.ext4 -F "$ROOT_PART"
    mkfs.fat -F32 "$EFI_PART"

    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
}

# ---------------------------
# Базовая установка
# ---------------------------
install_base() {
    log_info "Установка базовой системы..."
    pacstrap /mnt base base-devel linux linux-firmware networkmanager sudo vim git \
        &>>"$LOG_FILE"

    genfstab -U /mnt >> /mnt/etc/fstab

    arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Локаль
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Пользователь
useradd -m -G wheel,audio,video,optical,storage $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

# Sudo
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Сервисы
systemctl enable NetworkManager
EOF
}

# ---------------------------
# Установка загрузчика
# ---------------------------
install_grub() {
    arch-chroot /mnt pacman -S --noconfirm grub efibootmgr &>>"$LOG_FILE"
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB &>>"$LOG_FILE"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg &>>"$LOG_FILE"
}

# ---------------------------
# Установка Hyprland desktop
# ---------------------------
install_hyprland() {
arch-chroot /mnt pacman -S --noconfirm \
    hyprland \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal \
    rofi \
    waybar \
    hyprlock \
    swaync \
    wlogout \
    kitty \
    sddm \
    polkit \
    polkit-gnome \
    qt5-wayland \
    qt6-wayland \
    pipewire \
    pipewire-pulse \
    wireplumber \
    grim \
    slurp \
    wl-clipboard \
    brightnessctl \
    pavucontrol \
    noto-fonts \
    ttf-jetbrains-mono-nerd

arch-chroot /mnt systemctl enable sddm

arch-chroot /mnt /bin/bash <<EOF
mkdir -p /home/$USERNAME/.config/hypr

cat > /home/$USERNAME/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1

\$mainMod = SUPER

# Terminal
bind = \$mainMod, RETURN, exec, kitty

# Launcher
bind = \$mainMod, D, exec, rofi -show drun

# Windows
bind = \$mainMod, Q, killactive
bind = \$mainMod, F, fullscreen

# Bar / Notifications
exec-once = waybar
exec-once = swaync

# Lock
bind = \$mainMod, L, exec, hyprlock

# Power menu
bind = \$mainMod, ESCAPE, exec, wlogout

bindm = \$mainMod, mouse:272, movewindow
bindm = \$mainMod, mouse:273, resizewindow
HYPR

chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF
}

# ---------------------------
# Запуск установки
# ---------------------------
main() {
    clear
    log_info "=== Запуск Arch Linux Hyprland Installer ==="
    check_uefi
    check_internet
    mount_partitions
    install_base
    install_grub
    install_hyprland
    log_info "Установка завершена! Размонтируйте /mnt и перезагрузитесь."
}

main
