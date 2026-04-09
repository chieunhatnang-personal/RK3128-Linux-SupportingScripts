# 1) Backup boot env and DTB
cp -a /boot/armbianEnv.txt /boot/armbianEnv.txt.bak.codex-20260405-1
cp -a /boot/dtb-6.6.89-rk3128+/rk3128-linux.dtb /boot/dtb-6.6.89-rk3128+/rk3128-linux.dtb.bak-rng-test

# 2) Disable plymouth so early boot messages stay visible
if grep -q '^extraargs=' /boot/armbianEnv.txt; then
    grep -q '^extraargs=.*plymouth\.enable=0' /boot/armbianEnv.txt || \
    sed -i 's/^extraargs=\(.*\)$/extraargs=\1 plymouth.enable=0/' /boot/armbianEnv.txt
else
    echo 'extraargs=plymouth.enable=0' >> /boot/armbianEnv.txt
fi

# 3) Prevent serial login on ttyS1 from clearing the screen
mkdir -p /etc/systemd/system/serial-getty@ttyS1.service.d
cat > /etc/systemd/system/serial-getty@ttyS1.service.d/10-noclear.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 --noclear - $TERM
EOF

# 4) Reduce startup timeout for NetworkManager and wpa_supplicant
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/10-boot-timeout.conf <<'EOF'
[Service]
TimeoutStartSec=30s
EOF

mkdir -p /etc/systemd/system/wpa_supplicant.service.d
cat > /etc/systemd/system/wpa_supplicant.service.d/10-boot-timeout.conf <<'EOF'
[Service]
TimeoutStartSec=25s
EOF

# 5) Move broken empty NetworkManager profiles out of the active directory
mkdir -p /root/networkmanager-disabled-connections
for f in \
    /etc/NetworkManager/system-connections/Linksys-SilverMoonlight.nmconnection \
    /etc/NetworkManager/system-connections/OpenWrt.nmconnection \
    /etc/NetworkManager/system-connections/*.disabled-empty
do
    [ -e "$f" ] || continue
    mv "$f" /root/networkmanager-disabled-connections/
done

# 6) Reload systemd and NetworkManager
systemctl daemon-reload
nmcli connection reload || true

# 7) Reboot
reboot

