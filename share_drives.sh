#!/bin/bash

echo "📂 CONFIGURING WINDOWS FILE SHARING..."

# 1. Backup original config
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# 2. Define the Share Configuration
# We use a 'Here Document' to overwrite the config with a clean, permissive one.
sudo bash -c 'cat <<EOF > /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   server string = AI God Server
   security = user
   map to guest = Bad User
   dns proxy = no

# --- SHARES ---

[NVMe_Cloud]
   path = /mnt/cloud_storage
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0777
   directory mask = 0777

[HDD_1]
   path = /mnt/data_1
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0777
   directory mask = 0777

[HDD_2]
   path = /mnt/data_2
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0777
   directory mask = 0777

[HDD_3]
   path = /mnt/data_3
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0777
   directory mask = 0777

[HDD_4]
   path = /mnt/data_4
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0777
   directory mask = 0777

[HDD_5]
   path = /mnt/data_5
   browsable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0777
   directory mask = 0777
EOF'

# 3. Restart Samba to apply
echo "🔄 Restarting Samba Service..."
sudo systemctl restart smbd
sudo systemctl restart nmbd

echo "✅ File Sharing Configured."