#!/bin/bash

# Function for showing a spinner during long operations
spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\\'
    local temp

    while true; do
        temp="${spinstr#?}"
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        kill -0 "$pid" 2>/dev/null || break
        printf "\b\b\b\b\b\b"
    done
    echo " Done!"
}

# Show an introductory message
echo -e "\n\e[1;32mStarting WordPress Installation...\e[0m\n"

# Enable firewall and allow SSH
echo "Enabling firewall and allowing SSH..."
ufw enable & spinner

# Install necessary packages
echo "Updating packages and installing dependencies..."
sudo apt update & spinner
sudo apt install -y nginx software-properties-common unzip mariadb-server mariadb-client & spinner
ufw allow 'Nginx Full' & spinner

# Install PHP 8.4
echo "Installing PHP 8.4 and necessary PHP extensions..."
sudo add-apt-repository ppa:ondrej/php -y & spinner
sudo apt update & spinner
sudo apt install -y php8.4-fpm php8.4-common php8.4-dom php8.4-intl php8.4-mysql php8.4-xml php8.4-xmlrpc php8.4-curl php8.4-gd php8.4-imagick php8.4-cli php8.4-dev php8.4-imap php8.4-mbstring php8.4-soap php8.4-zip php8.4-bcmath & spinner

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
echo "Creating the database and user..."
sudo mariadb <<EOF & spinner
CREATE DATABASE ${dbname};
CREATE USER ${dbuser}@localhost IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO ${dbuser}@localhost;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';  
FLUSH PRIVILEGES;
EXIT;
EOF

# Download and set up WordPress
echo "Setting up WordPress..."
mkdir -p /var/www/${domain} & spinner
cd /var/www/${domain}
wget https://wordpress.org/latest.zip -O wordpress.zip & spinner
unzip wordpress.zip & spinner
rm wordpress.zip & spinner

# Configure Nginx for the domain
echo "Configuring Nginx for the domain..."
sudo tee /etc/nginx/sites-available/${domain} <<EOF & spinner
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
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
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
sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/ & spinner
mkdir /etc/ssl/${domain} & spinner

# User prompt for SSL certificates
echo -e "\n\e[1;33mPlease upload your certificate to /etc/ssl/${domain}/cert.pem and your private key to /etc/ssl/${domain}/key.pem.\e[0m"
echo -e "\nPress any key to continue after uploading your files..."
read -n 1 -s -r

# Configure SSL certificates
sudo nano /etc/ssl/${domain}/cert.pem
sudo nano /etc/ssl/${domain}/key.pem

# Set correct permissions
echo "Setting permissions for WordPress files..."
sudo chown -R www-data:www-data /var/www/${domain}/wordpress/ & spinner
sudo chmod 755 /var/www/${domain}/wordpress/wp-content & spinner

# Modify Nginx configuration for security limits
echo "Modifying Nginx configuration for rate limiting and timeouts..."
sudo sed -i '/http {/a \ \ \ \ limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;\n\ \ \ \ limit_conn_zone \$binary_remote_addr zone=addr:10m;\n\ \ \ \ client_body_timeout 10s;\n\ \ \ \ client_header_timeout 10s;\n\ \ \ \ send_timeout 10s;' /etc/nginx/nginx.conf & spinner

# Restart Nginx
echo "Restarting Nginx..."
sudo systemctl restart nginx & spinner

# Perform curl request and display response headers in terminal
echo -e "\n\e[1;32mChecking the HTTP response headers...\e[0m"
echo -e "\n\e[1;34m--------------------------------------\e[0m"
curl -I http://www.${domain} | tee /dev/tty
echo -e "\n\e[1;34m--------------------------------------\e[0m"

# Final message to user
echo -e "\n\e[1;32mWordPress installation completed. Please visit http://${domain} to access your WordPress website.\e[0m"
