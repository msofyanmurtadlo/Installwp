#!/bin/bash

# Step 1 - Enable UFW
ufw enable

# Step 2 - Allow SSH
ufw allow ssh

# Step 3 - Install Nginx
sudo apt install nginx -y

# Step 4 - Allow Nginx Full
sudo ufw allow 'Nginx Full'

# Step 5 - Install Software Properties
sudo apt-get install software-properties-common -y

# Step 6 - Install PHP 8.4 and necessary PHP extensions
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
sudo apt install php8.4-fpm php8.4-common php8.4-dom php8.4-intl php8.4-mysql php8.4-xml php8.4-xmlrpc php8.4-curl php8.4-gd php8.4-imagick php8.4-cli php8.4-dev php8.4-imap php8.4-mbstring php8.4-soap php8.4-zip php8.4-bcmath -y

# Step 7 - Install MariaDB Server and Client
sudo apt-get update
sudo apt-get install mariadb-server mariadb-client -y

# Step 8 - Ask user for database details
echo "Enter your domain (e.g. example.com):"
read domain

echo "Enter your database username:"
read dbuser

echo "Enter your database password:"
read dbpass

echo "Enter the name of your database:"
read dbname

# Step 9 - Create user and database with provided inputs using MariaDB SQL script
sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';
FLUSH PRIVILEGES;
EXIT;
EOF

# Step 10 - Create WordPress directory
mkdir /var/www/${domain}

# Step 11 - Navigate to the directory
cd /var/www/${domain}

# Step 12 - Download and unzip WordPress
wget https://wordpress.org/latest.zip
apt install unzip -y
unzip latest.zip
rm -r latest.zip

# Step 13 - Configure Nginx for the new domain
sudo tee /etc/nginx/sites-enabled/${domain} <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name www.${domain} ${domain};
    root /var/www/${domain}/wordpress/;
    index index.php index.html index.htm index.nginx-debian.html;

    error_log /var/log/nginx/${domain}.error;
    access_log /var/log/nginx/${domain}.access;

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
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        include snippets/fastcgi-php.conf;
        fastcgi_buffers 1024 4k;
        fastcgi_buffer_size 128k;
    }

    # Enable gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_comp_level 5;
    gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;
    gzip_proxied any;

    # A long browser cache lifetime can speed up repeat visits to your page
    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
        access_log off;
        log_not_found off;
        expires 360d;
    }

    # Disable access to hidden files
    location ~ /\.ht {
        access_log off;
        log_not_found off;
        deny all;
    }
}
EOF

mkdir /etc/ssl/${domain}
# Step 14 - SSL Configuration (if using SSL)
echo "You can now edit your SSL certificate and key using nano."
echo "Please make sure to copy your certificate to /etc/ssl/${domain}/cert.pem"
echo "and your private key to /etc/ssl/${domain}/key.pem"
echo "Press any key to continue when you are ready."

# Pause to allow user to edit SSL certificate and key
read -n 1 -s -r -p "Press any key to continue..."

# Open certificate and key files in nano
sudo nano /etc/ssl/${domain}/cert.pem
sudo nano /etc/ssl/${domain}/key.pem

# Step 15 - Apply SSL configuration in Nginx
sudo tee -a /etc/nginx/sites-enabled/${domain} <<EOF
# SSL configuration
listen 443 ssl http2;
listen [::]:443 ssl http2;
ssl_certificate         /etc/ssl/${domain}/cert.pem;
ssl_certificate_key     /etc/ssl/${domain}/key.pem;
EOF

# Step 16 - Set Permissions
sudo chown -R www-data:www-data /var/www/${domain}/wordpress/
sudo chmod 755 /var/www/${domain}/wordpress/wp-content

# Step 17 - Remove keepalive_timeout setting in Nginx config (default removed)
sudo tee -a /etc/nginx/nginx.conf <<EOF
limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=addr:10m;
client_body_timeout   10s;
client_header_timeout 10s;
send_timeout          10s;
EOF

# Step 18 - Restart Nginx to apply changes
sudo service nginx restart

echo "WordPress installation completed with PHP 8.4, MariaDB configured, Nginx set up, and SSL certificates applied!"
