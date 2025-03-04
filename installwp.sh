#!/bin/bash

# Enable UFW (Firewall)
ufw enable
ufw allow ssh
ufw allow 'Nginx Full'

# Install necessary packages
sudo apt update
sudo apt install -y nginx software-properties-common unzip mariadb-server mariadb-client

# Install PHP 8.4 and required extensions
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
sudo apt install -y php8.4-fpm php8.4-common php8.4-dom php8.4-intl php8.4-mysql php8.4-xml php8.4-xmlrpc php8.4-curl php8.4-gd php8.4-imagick php8.4-cli php8.4-dev php8.4-imap php8.4-mbstring php8.4-soap php8.4-zip php8.4-bcmath

# Ask user for database details
echo "Enter your domain (e.g. example.com):"
read domain
echo "Enter your database username:"
read dbuser
echo "Enter your database password:"
read dbpass
echo "Enter the name of your database:"
read dbname

# Create database and user
sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';
FLUSH PRIVILEGES;
EXIT;
EOF

# Validate database and user creation
DB_EXISTS=$(sudo mariadb -e "SHOW DATABASES LIKE '${dbname}';" | grep "${dbname}")
if [ -z "$DB_EXISTS" ]; then
    echo "Error: Database ${dbname} was not created successfully!"
    exit 1
else
    echo "Database ${dbname} created successfully!"
fi

USER_EXISTS=$(sudo mariadb -e "SELECT User FROM mysql.user WHERE User = '${dbuser}';" | grep "${dbuser}")
if [ -z "$USER_EXISTS" ]; then
    echo "Error: User ${dbuser} was not created successfully!"
    exit 1
else
    echo "User ${dbuser} created successfully!"
fi

# Create WordPress directory
mkdir -p /var/www/${domain}
cd /var/www/${domain}

# Download and unzip WordPress
wget https://wordpress.org/latest.zip -O wordpress.zip
if [ $? -ne 0 ]; then
    echo "Error: Failed to download WordPress!"
    exit 1
fi
unzip wordpress.zip
rm wordpress.zip

# Configure Nginx for the new domain
sudo tee /etc/nginx/sites-available/${domain} <<EOF
server {
    listen 80;
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

# Enable the Nginx site configuration
sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/

# Set up SSL (optional)
mkdir /etc/ssl/${domain}

echo "Please make sure to upload your certificate to /etc/ssl/${domain}/cert.pem"
echo "and your private key to /etc/ssl/${domain}/key.pem"
read -n 1 -s -r -p "Press any key when you're ready..."

# Open SSL certificate and key files for editing
sudo nano /etc/ssl/${domain}/cert.pem
sudo nano /etc/ssl/${domain}/key.pem

# Add SSL configuration in Nginx
sudo tee -a /etc/nginx/sites-enabled/${domain} <<EOF
listen 443 ssl http2;
ssl_certificate /etc/ssl/${domain}/cert.pem;
ssl_certificate_key /etc/ssl/${domain}/key.pem;
EOF

# Set permissions for WordPress files
sudo chown -R www-data:www-data /var/www/${domain}/wordpress/
sudo chmod 755 /var/www/${domain}/wordpress/wp-content

# Add additional Nginx configurations
sudo tee -a /etc/nginx/nginx.conf <<EOF
http {
    limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;
    limit_conn_zone \$binary_remote_addr zone=addr:10m;
    client_body_timeout 10s;
    client_header_timeout 10s;
    send_timeout 10s;
}
EOF

# Restart Nginx to apply changes
sudo systemctl restart nginx

# Check Nginx status
sudo systemctl status nginx

# Verify if the website is accessible via curl
curl -I http://www.${domain}

echo "WordPress installation completed. Please visit http://${domain} to access your WordPress website."
