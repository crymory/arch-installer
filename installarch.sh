#!/usr/bin/env bash
set -e

log() { echo -e "\e[1;32m==>\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }

[[ -d /sys/firmware/efi ]] || err "UEFI system required"

log "Checking internet connection..."
ping -c 2 8.8.8.8 >/dev/null || err "No internet connection. Connect via iwctl."

log "Syncing system clock and updating keyring..."
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring

log "Available disks:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""

read -rp "Disk with main system (e.g. nvme0n1): " DISK
DISK="${DISK#/dev/}"
DISK="/dev/$DISK"
[[ -b "$DISK" ]] || err "Disk $DISK not found"

# Функция установки
run_install() {
    local root_part=$1
    local efi_part=$2

    log "Target Root: $root_part"
    log "Target EFI:  $efi_part"

    log "Formatting $root_part as ext4..."
    mkfs.ext4 -F "$root_part"
    
    log "Mounting..."
    mount "$root_part" /mnt
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi || err "Failed to mount EFI partition $efi_part"

    # Определение микрокода
    local ucode=""
    if lscpu | grep -q "Intel"; then
        ucode="intel-ucode"
        log "Detected Intel CPU, adding microcode..."
    elif lscpu | grep -q "AMD"; then
        ucode="amd-ucode"
        log "Detected AMD CPU, adding microcode..."
    fi

    log "Installing base system..."
    # Добавили шрифты, микрокод и необходимые утилиты
    pacstrap /mnt base linux linux-firmware $ucode sudo networkmanager vim git base-devel \
        ttf-jetbrains-mono ttf-font-awesome noto-fonts noto-fonts-cjk noto-fonts-emoji --noconfirm

    genfstab -U /mnt >> /mnt/etc/fstab

    log "Creating Swapfile (4GB)..."
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=4096 status=progress
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
    swapon /mnt/swapfile
    echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

    log "Entering chroot..."
    arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc

# --- НАСТРОЙКА РУССКОГО ЯЗЫКА ---
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=ru_RU.UTF-8' > /etc/locale.conf
# Настройка консоли для кириллицы (иначе будут квадратики в TTY)
echo 'KEYMAP=ru' > /etc/vconsole.conf
echo 'FONT=cyr-sun16' >> /etc/vconsole.conf
# --------------------------------

echo arch-hypr > /etc/hostname

useradd -m -G wheel anc
echo "anc:anc" | chpasswd
echo "root:anc" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

pacman -S --noconfirm grub efibootmgr os-prober
# os-prober нужен, если есть Windows, чтобы Grub её увидел
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub 

# Ставим Hyprland и сопутствующие
pacman -S --noconfirm hyprland xorg-xwayland mesa libinput seatd waybar rofi kitty \
    pipewire pipewire-pulse wireplumber wl-clipboard grim slurp sddm \
    polkit-gnome thunar file-roller
    
systemctl enable sddm seatd

# --- GPU CONFIGURATION ---
GPU_TYPE=""
if lspci | grep -Ei "nvidia" >/dev/null; then
    GPU_TYPE="nvidia"
    pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
    # Фикс для Nvidia на Wayland в Grub
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1 /' /etc/default/grub
elif lspci | grep -Ei "amd|radeon" >/dev/null; then
    pacman -S --noconfirm vulkan-radeon libva-mesa-driver mesa-vdpau
elif lspci | grep -Ei "intel" >/dev/null; then
    pacman -S --noconfirm vulkan-intel intel-media-driver
fi

# Установка загрузчика (после настройки параметров ядра)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch-Hypr
grub-mkconfig -o /boot/grub/grub.cfg

# Базовый конфиг Hyprland
mkdir -p /home/anc/.config/hypr
cat > /home/anc/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1
\$mainMod=SUPER
bind=\$mainMod,RETURN,exec,kitty
bind=\$mainMod,D,exec,rofi -show drun
bind=\$mainMod,Q,killactive
bind=\$mainMod,M,exit
exec-once=waybar
env = XCURSOR_SIZE,24
input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle
}
HYPR

if [ "\$GPU_TYPE" == "nvidia" ]; then
    echo "env = LIBVA_DRIVER_NAME,nvidia" >> /home/anc/.config/hypr/hyprland.conf
    echo "env = XDG_SESSION_TYPE,wayland" >> /home/anc/.config/hypr/hyprland.conf
    echo "env = GBM_BACKEND,nvidia-drm" >> /home/anc/.config/hypr/hyprland.conf
    echo "env = __GLX_VENDOR_LIBRARY_NAME,nvidia" >> /home/anc/.config/hypr/hyprland.conf
fi

chown -R anc:anc /home/anc

# Установка YAY (AUR Helper) - опционально, но полезно
# Запускаем от пользователя anc, т.к. макепкг нельзя от рута
sudo -u anc bash -c 'cd ~ && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm'
EOF

    log "✅ Done! Unmount and reboot."
    umount -R /mnt
}

# Вывод разметки для пользователя
log "Current partitions on $DISK:"
lsblk "$DISK" -o NAME,SIZE,FSTYPE,PARTLABEL

read -rp "Which partition for Arch (Root)? (number, e.g. 5): " ROOT_NUM
[[ "$DISK" =~ nvme ]] && ROOT_P="${DISK}p${ROOT_NUM}" || ROOT_P="${DISK}${ROOT_NUM}"

read -rp "Which partition for EFI? (number, e.g. 1): " EFI_NUM
[[ "$DISK" =~ nvme ]] && EFI_P="${DISK}p${EFI_NUM}" || EFI_P="${DISK}${EFI_NUM}"

[[ -b "$ROOT_P" ]] || err "Root partition $ROOT_P not found"
[[ -b "$EFI_P" ]] || err "EFI partition $EFI_P not found"

read -rp "⚠️  Format $ROOT_P and install? (yes): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || err "Cancelled"

run_install "$ROOT_P" "$EFI_P"
