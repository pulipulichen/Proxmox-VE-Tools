#!/usr/bin/env bash

apt update && apt install -y curl gnupg2 wget ca-certificates

# 下載金鑰
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

# 新增軟體源 (使用無訂閱版本 pbs-no-subscription)
echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" > /etc/apt/sources.list.d/pbs-install.list

# 更新清單
apt update

apt install -y proxmox-backup-server

systemctl start proxmox-backup-proxy

echo "=============================="
echo "Proxmox Backup Server is Ready"
echo "=============================="