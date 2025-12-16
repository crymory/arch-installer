#!/usr/bin/env bash


mount | grep -q "$ROOT_PART" && err "ROOT уже смонтирован"


read -rp "⚠️ ФОРМАТИРОВАТЬ $ROOT_PART ? (yes): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && err "Отменено"


mkfs.ext4 "$ROOT_PART"


mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi


log "Интернет проверка"
ping -c 2 archlinux.org >/dev/null || err "Нет интернета"


log "Установка базы"
pacstrap /mnt base linux linux-firmware sudo networkmanager vim git


genfstab -U /mnt >> /mnt/etc/fstab


arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc


sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf


echo arch-hypr > /etc/hostname


useradd -m -G wheel anc
echo "anc:anc" | chpasswd
echo "root:anc" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers


systemctl enable NetworkManager


pacman -S --noconfirm grub efibootmgr


grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch-Hypr
grub-mkconfig -o /boot/grub/grub.cfg


pacman -S --noconfirm \
hyprland xorg-xwayland mesa libinput seatd \
waybar rofi kitty \
pipewire pipewire-pulse wireplumber \
wl-clipboard grim slurp \
sddm


systemctl enable sddm seatd


mkdir -p /home/anc/.config/hypr
cat > /home/anc/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1
\$mainMod=SUPER
bind=\$mainMod,RETURN,exec,kitty
bind=\$mainMod,D,exec,rofi -show drun
bind=\$mainMod,Q,killactive
exec-once=waybar
HYPR


chown -R anc:anc /home/anc
EOF


# --- GPU auto-detect ---
GPU_PKGS="mesa"


if lspci | grep -Ei "nvidia"; then
GPU_PKGS="mesa nvidia nvidia-utils nvidia-settings"
elif lspci | grep -Ei "amd|radeon"; then
GPU_PKGS="mesa vulkan-radeon libva-mesa-driver mesa-vdpau"
elif lspci | grep -Ei "intel"; then
GPU_PKGS="mesa vulkan-intel intel-media-driver"
fi


pacman -S --noconfirm $GPU_PKGS


log "✅ Готово! reboot"
