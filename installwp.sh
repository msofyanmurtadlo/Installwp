#!/bin/bash

# Function to install a package silently and show progress bar
install_with_progress() {
    echo "Installing $1..."
    sudo apt install -y "$1" &>/dev/null &
    progress_bar
    echo -e "\e[1;32m$1 installed successfully.\e[0m"
}

# Function to show a progress bar for installation
progress_bar() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\\'
    while kill -0 "$pid" 2>/dev/null; do
        for i in {1..10}; do
            printf " [%c]  " "$spinstr"
            spinstr=${spinstr#?}${spinstr%"${spinstr#?}"}
            sleep $delay
            printf "\b\b\b\b\b\b"
        done
    done
    echo " Done!"
}

# Show an introductory message
echo -e "\n\e[1;32mStarting WordPress Installation...\e[0m\n"

# Enable firewall and allow SSH
echo "Configuring UFW (Firewall)..."
ufw enable -y &>/dev/null
ufw allow ssh &>/dev/null

# Install Fail2Ban
install_with_progress fail2ban

# Enable and start Fail2Ban
sudo systemctl enable fail2ban &>/dev/null
sudo systemctl start fail2ban &>/dev/null

# Configure Fail2Ban for SSH
echo "Configuring Fail2Ban for SSH..."
sudo tee /etc/fail2ban/jail.d/defaults-debian.conf &>/dev/null <<EOF
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 600
findtime = 600
EOF

# Install Fail2Ban protection for WordPress
echo "Configuring Fail2Ban for WordPress..."
sudo tee /etc/fail2ban/jail.d/wordpress.conf &>/dev/null <<EOF
[wordpress]
enabled = true
filter = wordpress
action = iptables[name=wordpress, port=http, protocol=tcp]
logpath = /var/www/*/wordpress/wp-content/debug.log
maxretry = 3
bantime = 600
findtime = 600
EOF

# Create Fail2Ban filter for WordPress
sudo tee /etc/fail2ban/filter.d/wordpress.conf &>/dev/null <<EOF
[Definition]
failregex = <HOST> -.*"(GET|POST).*wp-login.php
ignoreregex =
EOF

# Reload Fail2Ban
echo "Reloading Fail2Ban..."
sudo systemctl reload fail2ban &>/dev/null

# Update packages
echo "Updating package lists..."
sudo apt update &>/dev/null

# Install necessary software packages with progress bar
install_with_progress nginx
install_with_progress software-properties-common
install_with_progress unzip
install_with_progress mariadb-server
install_with_progress mariadb-client
ufw allow 'Nginx Full' &>/dev/null

# Install PHP 8.1 and required extensions
install_with_progress php8.1-fpm
install_with_progress php8.1-common
install_with_progress php8.1-dom
install_with_progress php8.1-intl
install_with_progress php8.1-mysql
install_with_progress php8.1-xml
install_with_progress php8.1-xmlrpc
install_with_progress php8.1-curl
install_with_progress php8.1-gd
install_with_progress php8.1-imagick
install_with_progress php8.1-cli
install_with_progress php8.1-dev
install_with_progress php8.1-imap
install_with_progress php8.1-mbstring
install_with_progress php8.1-soap
install_with_progress php8.1-zip
install_with_progress php8.1-bcmath

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
echo "Configuring Nginx for ${domain}..."
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

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;  # PHP 8.1 socket
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        include snippets/fastcgi-php.conf;
        fastcgi_buffers 1024 4k;
        fastcgi_buffer_size 128k;
    }

    gzip on;
    gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;
    gzip_proxied any;

    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
        access_log off;
        log_not_found off;
        expires 360d;
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

# Display success message
echo -e "\n\e[1;34m--------------------------------------\e[0m"
echo -e "\n\e[1;32mWordPress installation for ${domain} completed successfully!\e[0m"
echo -e "\n\e[1;34m--------------------------------------\e[0m"
