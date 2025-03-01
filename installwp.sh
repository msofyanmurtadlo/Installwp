#!/bin/bash

echo "Masukkan nama domain (contoh: namadomain.com):"
read domain

echo "Masukkan nama database (contoh: wordpress_db):"
read dbname

echo "Masukkan username database (contoh: wordpressuser):"
read dbuser

echo "Masukkan password database:"
read -s dbpass

if ! ufw status | grep -q "Status: active"; then
    ufw enable
fi

ufw allow ssh

sudo apt update && sudo apt upgrade -y

sudo apt install nginx -y

sudo ufw allow 'Nginx Full'

sudo apt install -y lsb-release gnupg2 ca-certificates apt-transport-https software-properties-common

sudo add-apt-repository ppa:ondrej/php

sudo apt install -y php8.3 php8.3-fpm php8.3-bcmath php8.3-xml php8.3-mysql php8.3-zip php8.3-intl php8.3-ldap php8.3-gd php8.3-cli php8.3-bz2 php8.3-curl php8.3-mbstring php8.3-imagick php8.3-tokenizer php8.3-opcache php8.3-redis php8.3-cgi

sudo apt install -y mariadb-server mariadb-client

sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER ${dbuser}@localhost IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO ${dbuser}@localhost;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';  
FLUSH PRIVILEGES;
EXIT;
EOF

if [ -d "/var/www/website1" ]; then
    echo "/var/www/website1 sudah ada."
    echo "Silakan masukkan nama folder baru untuk instalasi WordPress, misalnya website2:"
    read path
    path="/var/www/$path"
else
    path="/var/www/website1"
fi

if [ ! -d "$path" ]; then
    sudo mkdir -p $path
    echo "Direktori $path berhasil dibuat."
else
    echo "Direktori $path sudah ada."
fi

cd $path
sudo apt install wget
wget http://wordpress.org/latest.tar.gz
sudo tar -xzvf latest.tar.gz
rm -r latest.tar.gz
sudo chown -R www-data:www-data $path/wordpress/
sudo chmod -R 755 $path/wordpress/

sudo tee /etc/nginx/sites-available/${domain}.conf > /dev/null <<EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    root ${path}/wordpress;
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

sudo ln -s /etc/nginx/sites-available/${domain}.conf /etc/nginx/sites-enabled/

sudo apt install -y certbot python3-certbot-nginx

sudo certbot --nginx --agree-tos --redirect --email admin@${domain} -d ${domain},www.${domain}

sudo systemctl reload nginx

echo "Instalasi selesai! Anda dapat mengakses WordPress melalui https://${domain}."
