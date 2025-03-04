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
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
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
else
    echo "Direktori $path sudah ada."
fi

cd $path

sudo apt install wget -y
wget http://wordpress.org/latest.tar.gz
sudo tar -xzvf latest.tar.gz
rm -r latest.tar.gz
sudo chown -R www-data:www-data $path/wordpress/
sudo chmod -R 755 $path/wordpress/

sudo tee /etc/nginx/sites-available/${domain}.conf > /dev/null <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name www.${domain} ${domain};
  root ${path}/wordpress/;
  index index.php index.html index.htm index.nginx-debian.html;

  error_log /var/log/nginx/wordpress.error;
  access_log /var/log/nginx/wordpress.access;

  location / {
    limit_req zone=mylimit burst=20 nodelay;
    limit_conn addr 10;
    try_files \$uri \$uri/ /index.php;
  }

  location ~ ^/wp-json/ {
     rewrite ^/wp-json/(.*?)$ /?rest_route=/$1 last;
  }

  location ~* /wp-sitemap.*\.xml {
    try_files \$uri \$uri/ /index.php\$is_args\$args;
  }

  error_page 404 /404.html;
  error_page 500 502 503 504 /50x.html;

  client_max_body_size 20M;

  location = /50x.html {
    root /usr/share/nginx/html;
  }

  location ~ \.php$ {
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
    include snippets/fastcgi-php.conf;
    fastcgi_buffers 1024 4k;
    fastcgi_buffer_size 128k;
  }

  gzip on;
  gzip_vary on;
  gzip_min_length 1000;
  gzip_comp_level 5;
  gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;
  gzip_proxied any;

  location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
       access_log        off;
       log_not_found     off;
       expires           360d;
  }

  location ~ /\.ht {
      access_log off;
      log_not_found off;
      deny all;
  }
}
EOF

sudo ln -s /etc/nginx/sites-available/${domain}.conf /etc/nginx/sites-enabled/

sudo apt install -y certbot python3-certbot-nginx

sudo certbot --nginx --agree-tos --redirect --email admin@${domain} -d ${domain},www.${domain}

sudo systemctl reload nginx

echo "Instalasi selesai! Anda dapat mengakses WordPress melalui https://${domain}."
