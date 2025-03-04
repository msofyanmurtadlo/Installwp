#!/bin/bash

echo "Masukkan nama domain (contoh: domainku.com):"
read domain
echo "Masukkan nama database:"
read dbname
echo "Masukkan username database:"
read dbuser
echo "Masukkan password database:"
read -s dbpass

ufw enable
ufw allow ssh

# Install dependencies untuk PHP dan FrankenPHP
sudo apt-get install software-properties-common -y
sudo apt-get install apt-transport-https ca-certificates lsb-release curl -y

# Menambahkan FrankenPHP repository untuk PHP 8.4
echo "deb https://deb.php.frankenphp.dev $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/frankenphp.list
curl -fsSL https://packages.frankenphp.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/frankenphp.gpg
sudo apt-get update
sudo apt-get install frankenphp -y

# Install MariaDB
sudo apt install -y mariadb-server mariadb-client

# Setup database untuk WordPress
sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';
FLUSH PRIVILEGES;
EXIT;
EOF

# Install dan setup WordPress
sudo mkdir -p /var/www/${domain}
cd /var/www/${domain}
wget https://wordpress.org/latest.zip
sudo apt install zip -y
unzip latest.zip
rm -r latest.zip

# Konfigurasi Nginx untuk WordPress
sudo tee /etc/nginx/sites-available/${domain}.conf > /dev/null <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name www.${domain} ${domain};
  root /var/www/${domain}/wordpress/;
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
    frankenphp_pass;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
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

# SSL Configuration
sudo mkdir /etc/ssl/${domain}

# Menambahkan konfigurasi SSL pada Nginx
sudo tee -a /etc/nginx/sites-available/${domain}.conf > /dev/null <<EOF
listen 443 ssl http2;
listen [::]:443 ssl http2;
ssl_certificate         /etc/ssl/${domain}/cert.pem;
ssl_certificate_key     /etc/ssl/${domain}/key.pem;
EOF

# Set permissions untuk WordPress
sudo chown -R www-data:www-data /var/www/${domain}/wordpress/
sudo chmod 755 /var/www/${domain}/wordpress/wp-content

# Install Fail2Ban untuk perlindungan
sudo apt install fail2ban -y

# Konfigurasi Fail2Ban
sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[sshd]
enabled  = true
port     = ssh
logpath  = /var/log/auth.log
maxretry = 3

[wordpress]
enabled  = true
filter   = wordpress
logpath  = /var/www/${domain}/wordpress/wp-content/debug.log
maxretry = 5
EOF

sudo tee /etc/fail2ban/filter.d/wordpress.conf > /dev/null <<EOF
[Definition]
failregex = .*authentication failure.*OR.*login failed.*
ignoreregex =
EOF

# Install ModSecurity
sudo apt-get install -y libnginx-mod-http-modsecurity

# Aktifkan ModSecurity di Nginx
sudo tee -a /etc/nginx/nginx.conf > /dev/null <<EOF
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/main.conf;

limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=addr:10m;
client_body_timeout   10s;
client_header_timeout 10s;
send_timeout          10s;
EOF

# Restart layanan
sudo service nginx restart
sudo service fail2ban restart

echo "Instalasi selesai! Anda dapat mengakses WordPress melalui https://$domain"
