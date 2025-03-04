#!/bin/bash

# Input dari user
read -p "Masukkan domain (contoh: example.com): " DOMAIN
read -p "Masukkan nama database: " DBNAME
read -p "Masukkan nama pengguna database: " DBUSER
read -p "Masukkan kata sandi database dan root MariaDB: " DBPASS

# Pembaruan sistem
sudo apt update -y
sudo apt upgrade -y

# Menginstal dependensi yang diperlukan
sudo apt install -y \
    nginx \
    mariadb-server \
    curl \
    git \
    unzip \
    sudo \
    gnupg2 \
    lsb-release \
    ca-certificates \
    python3-certbot-nginx \
    certbot

# Instal PHP 8.4 dan dependensinya
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update -y
sudo apt install -y \
    php8.4-cli \
    php8.4-mysql \
    php8.4-curl \
    php8.4-json \
    php8.4-xml \
    php8.4-mbstring \
    php8.4-zip

# Install FrankenPHP
curl -sSL https://github.com/frankenphp/frankenphp/releases/download/v0.1.0/frankenphp-linux-amd64-v0.1.0.tar.gz -o /tmp/frankenphp.tar.gz
sudo tar -zxvf /tmp/frankenphp.tar.gz -C /usr/local/bin
sudo chmod +x /usr/local/bin/frankenphp

# Konfigurasi Nginx untuk FrankenPHP
sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/$DOMAIN
sudo bash -c "cat > /etc/nginx/sites-available/$DOMAIN" <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    
    root /var/www/$DOMAIN;
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Passthrough untuk FrankenPHP
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/frankenphp.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    location ~ /\.ht {
        deny all;
    }
}
EOL

# Aktifkan situs Nginx
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Install dan konfigurasikan MariaDB
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Mengamankan instalasi MariaDB dan mengatur password root dengan DBPASS
sudo mysql_secure_installation <<EOF
y
$DBPASS
$DBPASS
y
y
y
y
EOF

# Membuat database dan user untuk WordPress
sudo mariadb <<EOF
CREATE DATABASE $DBNAME;
CREATE USER '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $DBNAME.* TO '$DBUSER'@'localhost';
FLUSH PRIVILEGES;
EXIT;
EOF

# Install WordPress
cd /var/www/
sudo wget https://wordpress.org/latest.tar.gz
sudo tar -xvzf latest.tar.gz
sudo mv wordpress $DOMAIN
sudo chown -R www-data:www-data /var/www/$DOMAIN

# Konfigurasi WordPress
cd /var/www/$DOMAIN
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/database_name_here/$DBNAME/" wp-config.php
sudo sed -i "s/username_here/$DBUSER/" wp-config.php
sudo sed -i "s/password_here/$DBPASS/" wp-config.php
sudo sed -i "s/localhost/127.0.0.1/" wp-config.php

# Install dan mengonfigurasi SSL dengan Let's Encrypt
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email youremail@example.com

# Restart Nginx untuk memastikan semua konfigurasi diterapkan
sudo systemctl restart nginx

# Restart FrankenPHP
sudo systemctl restart frankenphp

# Memberikan izin folder dan file
sudo chown -R www-data:www-data /var/www/$DOMAIN

# Menyelesaikan instalasi WordPress melalui browser
echo "Instalasi selesai! Silakan buka https://$DOMAIN untuk melanjutkan pengaturan WordPress."
