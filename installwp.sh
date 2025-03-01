#!/bin/bash

# Meminta input untuk domain, user database dan password
echo "Masukkan nama domain (misalnya: namadomain.com): "
read DOMAIN

echo "Masukkan nama database: "
read DBNAME

echo "Masukkan username database: "
read DBUSER

echo "Masukkan password database: "
read DBPASS

# Step 1: Enable UFW (Firewall)
ufw enable

# Step 2: Allow SSH connections
ufw allow ssh

# Step 3: Update your system
sudo apt update && sudo apt upgrade -y

# Step 4: Install Nginx
sudo apt install nginx -y

# Step 5: Allow Nginx traffic through firewall
sudo ufw allow 'Nginx Full'

# Step 6: Install dependencies for PHP
sudo apt install -y lsb-release gnupg2 ca-certificates apt-transport-https software-properties-common

# Step 7: Add PHP repository
sudo add-apt-repository ppa:ondrej/php

# Step 8: Install PHP 8.3 and necessary PHP extensions
sudo apt install -y php8.3 php8.3-fpm php8.3-bcmath php8.3-xml php8.3-mysql php8.3-zip php8.3-intl php8.3-ldap php8.3-gd php8.3-cli php8.3-bz2 php8.3-curl php8.3-mbstring php8.3-imagick php8.3-tokenizer php8.3-opcache php8.3-redis php8.3-cgi

# Step 9: Install MariaDB server
sudo apt install -y mariadb-server mariadb-client

# Step 10: Login to MariaDB
sudo mariadb <<EOF
CREATE DATABASE $DBNAME;
CREATE USER $DBUSER@localhost IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $DBNAME.* TO $DBUSER@localhost;
FLUSH PRIVILEGES;
EXIT;
EOF

# Step 11: Go to your web server's root directory
cd /var/www/

# Step 12: Download WordPress
sudo apt install wget && wget http://wordpress.org/latest.tar.gz

# Step 13: Extract WordPress
sudo tar -xzvf latest.tar.gz

# Step 14: Clean up tarball
rm -r latest.tar.gz

# Step 15: Set correct ownership for WordPress files
sudo chown -R www-data:www-data /var/www/wordpress/

# Step 16: Set proper file permissions
sudo chmod -R 755 /var/www/wordpress/

# Step 17: Create Nginx configuration file for WordPress
sudo bash -c "cat > /etc/nginx/sites-available/wordpress.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /var/www/wordpress;
    index index.php;
    autoindex off;
    access_log /var/log/nginx/$DOMAIN-access.log combined;
    error_log /var/log/nginx/$DOMAIN-error.log;
    
    client_max_body_size 10M;
    client_body_buffer_size 128k;
    client_body_timeout 10;
    client_header_timeout 10;
    keepalive_timeout 5;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
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
}
EOF"

# Step 18: Enable the WordPress site by creating a symbolic link
sudo ln -s /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/

# Step 19: Install Certbot and Nginx plugin for SSL
sudo apt install -y certbot python3-certbot-nginx

# Step 20: Obtain an SSL certificate using Certbot
sudo certbot --nginx --agree-tos --redirect --email admin@$DOMAIN -d $DOMAIN,www.$DOMAIN

# Step 21: Test the Nginx configuration for errors
sudo nginx -t

# Step 22: Reload Nginx to apply the SSL and configuration changes
sudo systemctl reload nginx

# Optional Step 23: Clean up temporary files (if needed)
sudo apt autoremove -y
