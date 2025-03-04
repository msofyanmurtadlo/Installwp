#!/bin/bash

# Install dialog untuk UI yang lebih interaktif
sudo apt install -y dialog

# Fungsi untuk menampilkan progress
progress_bar() {
    (
    for i in {1..100}; do
        echo $i
        sleep 0.05
    done
    ) | dialog --gauge "Installing Packages" 10 70 0
}

# Fungsi untuk menampilkan pesan konfirmasi
info_message() {
    dialog --msgbox "$1" 10 50
}

# Menyembunyikan proses awal dengan progress bar
progress_bar

# Enable firewall and allow SSH
ufw enable
ufw allow ssh

# Installing required packages
sudo apt update
sudo apt install -y nginx software-properties-common unzip mariadb-server mariadb-client
ufw allow 'Nginx Full'

# Installing PHP 8.4 and related extensions
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
sudo apt install -y php8.4-fpm php8.4-common php8.4-dom php8.4-intl php8.4-mysql php8.4-xml php8.4-xmlrpc php8.4-curl php8.4-gd php8.4-imagick php8.4-cli php8.4-dev php8.4-imap php8.4-mbstring php8.4-soap php8.4-zip php8.4-bcmath

# Prompt for domain and database details
domain=$(dialog --inputbox "Enter your domain (e.g. example.com):" 8 40 3>&1 1>&2 2>&3)
dbname=$(dialog --inputbox "Enter the name of your database:" 8 40 3>&1 1>&2 2>&3)
dbuser=$(dialog --inputbox "Enter your database username:" 8 40 3>&1 1>&2 2>&3)
dbpass=$(dialog --passwordbox "Enter your database password:" 8 40 3>&1 1>&2 2>&3)

# Create database and user
sudo mariadb <<EOF
CREATE DATABASE ${dbname};
CREATE USER ${dbuser}@localhost IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO ${dbuser}@localhost;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${dbpass}';  
FLUSH PRIVILEGES;
EXIT;
EOF

# Create the WordPress directory and download files
mkdir -p /var/www/${domain}
cd /var/www/${domain}
wget https://wordpress.org/latest.zip -O wordpress.zip
unzip wordpress.zip
rm wordpress.zip

# Configure Nginx
sudo tee /etc/nginx/sites-available/${domain} <<EOF
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

# Create symbolic link to enable site
sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/

# Create SSL directory
mkdir /etc/ssl/${domain}

# Show message to user to upload certificates
info_message "Please upload your certificate to /etc/ssl/${domain}/cert.pem and your private key to /etc/ssl/${domain}/key.pem. Press any key when you're ready..."

# User will upload the cert.pem and key.pem files
sudo nano /etc/ssl/${domain}/cert.pem
sudo nano /etc/ssl/${domain}/key.pem

# Set file permissions
sudo chown -R www-data:www-data /var/www/${domain}/wordpress/
sudo chmod 755 /var/www/${domain}/wordpress/wp-content

# Modify Nginx configuration for limits and timeouts
sudo sed -i '/http {/a \ \ \ \ limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;\n\ \ \ \ limit_conn_zone \$binary_remote_addr zone=addr:10m;\n\ \ \ \ client_body_timeout 10s;\n\ \ \ \ client_header_timeout 10s;\n\ \ \ \ send_timeout 10s;' /etc/nginx/nginx.conf

# Restart Nginx
sudo systemctl restart nginx

# Perform curl and display the result in a dialog box
http_response=$(curl -I http://www.${domain} 2>/dev/null | dialog --stdout --title "HTTP Response" --msgbox "$(curl -I http://www.${domain} 2>/dev/null)" 15 70)

# Show message confirming the completion
info_message "WordPress installation completed. Please visit http://${domain} to access your WordPress website."
