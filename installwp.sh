#!/bin/bash

read -p "Enter domain (e.g., domainku.com): " domain
read -p "Enter database name: " dbname
read -p "Enter database user: " dbuser
read -p "Enter database password: " dbpass

sudo apt update -y
sudo apt upgrade -y
sudo apt install ufw nginx zip mariadb-server mariadb-client apt-transport-https curl fail2ban -y

sudo add-apt-repository ppa:ondrej/php -y
sudo apt update -y
sudo apt install php8.4-fpm php8.4-common php8.4-dom php8.4-intl php8.4-mysql php8.4-xml php8.4-xmlrpc php8.4-curl php8.4-gd php8.4-imagick php8.4-cli php8.4-dev php8.4-imap php8.4-mbstring php8.4-soap php8.4-zip php8.4-bcmath -y

sudo ufw enable
sudo ufw allow ssh
sudo ufw allow 'Nginx Full'

sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';
FLUSH PRIVILEGES;
EXIT;
EOF

sudo mkdir /var/www/$domain
cd /var/www/$domain
sudo wget https://wordpress.org/latest.zip
sudo unzip latest.zip
sudo rm -r latest.zip

sudo tee /etc/nginx/sites-available/$domain <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name www.$domain $domain;
  root /var/www/$domain/wordpress/;
  index index.php index.html index.htm index.nginx-debian.html;

  error_log /var/log/nginx/wordpress.error;
  access_log /var/log/nginx/wordpress.access;

  location / {
    limit_req zone=mylimit burst=20 nodelay;
    limit_conn addr 10;
    try_files \$uri \$uri/ /index.php;
  }

  location ~ ^/wp-json/ {
    rewrite ^/wp-json/(.*?)\$ /?rest_route=/$1 last;
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

  location ~ \.php\$ {
    fastcgi_pass unix:/run/php/php8.4-fpm.sock;
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

  location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)\$ {
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

sudo ln -s /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/

sudo tee -a /etc/nginx/sites-available/$domain <<EOF
# SSL configuration

listen 443 ssl http2;
listen [::]:443 ssl http2;
ssl_certificate         /etc/ssl/$domain/cert.pem;
ssl_certificate_key     /etc/ssl/$domain/key.pem;
EOF

sudo chown -R www-data:www-data /var/www/$domain/wordpress/
sudo chmod 755 /var/www/$domain/wordpress/wp-content

sudo sed -i '/keepalive_timeout/d' /etc/nginx/nginx.conf
sudo tee -a /etc/nginx/nginx.conf <<EOF
limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=addr:10m;
client_body_timeout   10s;
client_header_timeout 10s;
keepalive_timeout     10s;
send_timeout          10s;
EOF

sudo service nginx restart

sudo tee /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 600
findtime = 600
EOF

sudo tee -a /etc/fail2ban/jail.local <<EOF
[wordpress]
enabled = true
port = http,https
filter = wordpress
logpath = /var/log/nginx/wordpress.error
maxretry = 3
bantime = 600
findtime = 600
EOF

sudo systemctl restart fail2ban

echo "Setup complete for $domain"
