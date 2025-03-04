#!/bin/bash

# Function to install a package silently and show progress
install_silently() {
    echo -n "Installing $1... "
    # Menjalankan apt-get dan menampilkan progress
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" --no-install-recommends | tee /dev/tty | tail -n 10
    echo -e "\e[1;32m$1 installed successfully.\e[0m"
}

# Show an introductory message
echo -e "\n\e[1;32mStarting WordPress Installation...\e[0m\n"

# Enable firewall and allow SSH
ufw enable &>/dev/null
ufw allow ssh &>/dev/null

# Update packages and install required software
echo "Installing required software..."
sudo apt update &>/dev/null
install_silently nginx
install_silently software-properties-common
install_silently unzip
install_silently mariadb-server
install_silently mariadb-client
ufw allow 'Nginx Full' &>/dev/null

# Install PHP 8.4
echo "Installing PHP 8.4..."
sudo add-apt-repository ppa:ondrej/php -y &>/dev/null
sudo apt update &>/dev/null
install_silently php8.4-fpm
install_silently php8.4-common
install_silently php8.4-dom
install_silently php8.4-intl
install_silently php8.4-mysql
install_silently php8.4-xml
install_silently php8.4-xmlrpc
install_silently php8.4-curl
install_silently php8.4-gd
install_silently php8.4-imagick
install_silently php8.4-cli
install_silently php8.4-dev
install_silently php8.4-imap
install_silently php8.4-mbstring
install_silently php8.4-soap
install_silently php8.4-zip
install_silently php8.4-bcmath

# Prompt for domain and database details
echo -e "\n\e[1;34mEnter your domain (e.g. example.com):\e[0m"
read domain
echo -e "\n\e[1;34mEnter the name of your database:\e[0m"
read dbname
echo -e "\n\e[1;34mEnter your database username:\e[0m"
read dbuser
echo -e "\n\e[1;34mEnter your database password:\e[0m"
read -s dbpass

# Create database and user
echo "Setting up database..."
sudo mariadb <<EOF &>/dev/null
CREATE DATABASE ${dbname};
CREATE USER ${dbuser}@localhost IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO ${dbuser}@localhost;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';  
FLUSH PRIVILEGES;
EXIT;
EOF

# Download and set up WordPress
echo "Setting up WordPress..."
mkdir -p /var/www/${domain} &>/dev/null
cd /var/www/${domain}
wget -q https://wordpress.org/latest.zip -O wordpress.zip &>/dev/null
unzip -q wordpress.zip &>/dev/null
rm -f wordpress.zip &>/dev/null

# Configure Nginx for the domain
echo "Configuring Nginx..."
sudo tee /etc/nginx/sites-available/${domain} &>/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;

    listen 443 ssl http2;
    ssl_certificate /etc/ssl/${domain}/cert.pem;
    ssl_certificate_key /etc/ssl/${domain}/key.pem;
    
    server_name ${domain} www.${domain};
    root /var/www/${domain}/wordpress/;
    index index.php index.html index.htm;

    error_log /var/log/nginx/${domain}.error;
    access_log /var/log/nginx/${domain}.access;

    location / {
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

    location ~ /\.ht {
        access_log off;
        log_not_found off;
        deny all;
    }
}
EOF

# Enable the site and create SSL directory
sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/ &>/dev/null
mkdir /etc/ssl/${domain} &>/dev/null

# User prompt for SSL certificates
echo -e "\n\e[1;33mPlease upload your certificate to /etc/ssl/${domain}/cert.pem and your private key to /etc/ssl/${domain}/key.pem.\e[0m"
echo -e "\nPress any key to continue after uploading your files..."
read -n 1 -s -r

# Configure SSL certificates
sudo nano /etc/ssl/${domain}/cert.pem
sudo nano /etc/ssl/${domain}/key.pem

# Set correct permissions
echo "Setting permissions for WordPress files..."
sudo chown -R www-data:www-data /var/www/${domain}/wordpress/ &>/dev/null
sudo chmod 755 /var/www/${domain}/wordpress/wp-content &>/dev/null

# Modify Nginx configuration for security limits
echo "Modifying Nginx configuration for rate limiting and timeouts..."
sudo sed -i '/http {/a \ \ \ \ limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;\n\ \ \ \ limit_conn_zone \$binary_remote_addr zone=addr:10m;\n\ \ \ \ client_body_timeout 10s;\n\ \ \ \ client_header_timeout 10s;\n\ \ \ \ send_timeout 10s;' /etc/nginx/nginx.conf &>/dev/null

# Restart Nginx
echo "Restarting Nginx..."
sudo systemctl restart nginx &>/dev/null

# Perform curl request and display response headers in terminal
echo -e "\n\e[1;32mChecking the HTTP response headers...\e[0m"
echo -e "\n\e[1;34m--------------------------------------\e[0m"
curl -I http://www.${domain} | tee /dev/tty
echo -e "\n\e[1;34m--------------------------------------\e[0m"

# Final message to user
echo -e "\n\e[1;32mWordPress installation completed. Please visit http://${domain} to access your WordPress website.\e[0m"
