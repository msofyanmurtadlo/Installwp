#!/bin/bash

# Meminta input untuk domain dan nama database
echo "Masukkan nama domain (contoh: namadomain.com):"
read domain

echo "Masukkan nama database (contoh: wordpress_db):"
read dbname

echo "Masukkan username database (contoh: wordpressuser):"
read dbuser

echo "Masukkan password database:"
read -s dbpass

# Step 1 - Memastikan UFW aktif
ufw enable

# Step 2 - Mengizinkan SSH
ufw allow ssh

# Step 3 - Memperbarui sistem
sudo apt update && sudo apt upgrade -y

# Step 4 - Instalasi Nginx
sudo apt install nginx -y

# Step 5 - Mengizinkan Nginx di firewall
sudo ufw allow 'Nginx Full'

# Step 6 - Instalasi dependensi untuk PHP
sudo apt install -y lsb-release gnupg2 ca-certificates apt-transport-https software-properties-common

# Step 7 - Menambahkan repository PHP
sudo add-apt-repository ppa:ondrej/php

# Step 8 - Instalasi PHP 8.3 dan ekstensi yang diperlukan
sudo apt install -y php8.3 php8.3-fpm php8.3-bcmath php8.3-xml php8.3-mysql php8.3-zip php8.3-intl php8.3-ldap php8.3-gd php8.3-cli php8.3-bz2 php8.3-curl php8.3-mbstring php8.3-imagick php8.3-tokenizer php8.3-opcache php8.3-redis php8.3-cgi

# Step 9 - Instalasi MariaDB
sudo apt install -y mariadb-server mariadb-client

# Step 10 - Mengonfigurasi Database
sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER ${dbuser}@localhost IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO ${dbuser}@localhost;
FLUSH PRIVILEGES;
EXIT;
EOF

# Step 11 - Menginstal WordPress
cd /var/www/
sudo apt install wget
wget http://wordpress.org/latest.tar.gz
sudo tar -xzvf latest.tar.gz
rm -r latest.tar.gz
sudo chown -R www-data:www-data /var/www/wordpress/
sudo chmod -R 755 /var/www/wordpress/

# Step 12 - Konfigurasi Nginx untuk WordPress
sudo tee /etc/nginx/sites-available/wordpress.conf > /dev/null <<EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    root /var/www/wordpress;
    index index.php;
    autoindex off;
    access_log /var/log/nginx/${domain}-access.log combined;
    error_log /var/log/nginx/${domain}-error.log;
    client_max_body_size 10M;
    client_body_buffer_size 128k;
    client_body_timeout 10;
    client_header_timeout 10;
    keepalive_timeout 5;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~* /(?:wp-content/uploads|wp-includes)/.*\.php$ {
        deny all;
    }

    location = /xmlrpc.php {
        deny all;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
        expires max;
    }

    location = /robots.txt {
        log_not_found off;
        access_log off;
    }

    location ~ /\. {
        deny all;
    }

    location /wp-content/uploads/ {
        location ~ \.php$ {
            deny all;
        }
    }

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Permitted-Cross-Domain-Policies none;
    add_header X-Frame-Options "SAMEORIGIN";

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_comp_level 5;
    gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;
    gzip_proxied any;

    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
        access_log off;
        log_not_found off;
        expires 360d;
    }

    location ~ ^/wp-json/ {
        rewrite ^/wp-json/(.*?)$ /?rest_route=/$1 last;
    }
}
EOF

# Step 13 - Menyambungkan konfigurasi Nginx ke direktori sites-enabled
sudo ln -s /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/

# Step 14 - Instalasi Certbot untuk SSL
sudo apt install -y certbot python3-certbot-nginx

# Step 15 - Memasang SSL menggunakan Certbot
sudo certbot --nginx --agree-tos --redirect --email admin@${domain} -d ${domain},www.${domain}

# Step 16 - Memuat ulang Nginx
sudo systemctl reload nginx

# Menyelesaikan
echo "Instalasi selesai! Anda dapat mengakses WordPress melalui https://${domain}."
