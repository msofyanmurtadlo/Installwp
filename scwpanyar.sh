#!/bin/bash

# Warna untuk output
MERAH='\033[0;31m'
HIJAU='\033[0;32m'
KUNING='\033[1;33m'
BIRU='\033[0;34m'
NC='\033[0m' # No Color

# Fungsi untuk menginstal paket secara diam dan menampilkan progress
install_with_progress() {
    echo -e "${BIRU}Menginstal paket: $@${NC}"
    sudo apt-get install -y "$@" > /dev/null 2>&1 &
    local pid=$!
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[${spin:$i:1}] Sedang menginstal..."
        sleep 0.1
    done
    printf "\r${HIJAU}✓ Paket berhasil diinstal.${NC}\n"
}

# Fungsi untuk memvalidasi domain
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${MERAH}Error: Format domain tidak valid${NC}"
        return 1
    fi
    return 0
}

# Fungsi untuk setup SSL dengan Certbot
setup_ssl() {
    local domain=$1
    
    echo -e "\n${BIRU}Mengatur SSL untuk ${domain}${NC}"
    
    # Izinkan HTTP sementara untuk challenge Certbot
    sudo ufw allow 80/tcp > /dev/null
    
    # Hentikan Nginx sementara untuk mode standalone Certbot
    sudo systemctl stop nginx > /dev/null
    
    # Dapatkan sertifikat SSL
    if sudo certbot certonly --standalone --agree-tos --no-eff-email --email admin@${domain} -d ${domain} -d www.${domain} > /dev/null 2>&1; then
        echo -e "${HIJAU}✓ Sertifikat SSL berhasil didapatkan${NC}"
        
        # Buat symlink ke path SSL standar
        sudo mkdir -p /etc/ssl/${domain} > /dev/null
        sudo ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /etc/ssl/${domain}/cert.pem
        sudo ln -sf /etc/letsencrypt/live/${domain}/privkey.pem /etc/ssl/${domain}/key.pem
        
        # Setup pembaruan otomatis
        (sudo crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\"") | sudo crontab -
        
        return 0
    else
        echo -e "${KUNING}Certbot gagal, melanjutkan dengan sertifikat self-signed${NC}"
        
        # Buat direktori untuk SSL
        sudo mkdir -p /etc/ssl/${domain} > /dev/null
        
        # Generate sertifikat self-signed
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/ssl/${domain}/key.pem \
            -out /etc/ssl/${domain}/cert.pem \
            -subj "/CN=${domain}" > /dev/null 2>&1
            
        return 1
    fi
}

# Fungsi untuk mengkonfigurasi WordPress
configure_wordpress() {
    local domain=$1
    local dbname=$2
    local dbuser=$3
    local dbpass=$4
    
    echo -e "\n${BIRU}Mengkonfigurasi WordPress untuk ${domain}${NC}"
    
    # Buat wp-config.php
    cp /var/www/${domain}/wordpress/wp-config-sample.php /var/www/${domain}/wordpress/wp-config.php
    
    # Set detail database
    sed -i "s/database_name_here/${dbname}/" /var/www/${domain}/wordpress/wp-config.php
    sed -i "s/username_here/${dbuser}/" /var/www/${domain}/wordpress/wp-config.php
    sed -i "s/password_here/${dbpass}/" /var/www/${domain}/wordpress/wp-config.php
    
    # Generate kunci keamanan
    SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    sed -i "/AUTH_KEY/s/put your unique phrase here/$SALT/" /var/www/${domain}/wordpress/wp-config.php
    
    # Set permission file
    sudo chown -R www-data:www-data /var/www/${domain}/wordpress/
    sudo find /var/www/${domain}/wordpress/ -type d -exec chmod 750 {} \;
    sudo find /var/www/${domain}/wordpress/ -type f -exec chmod 640 {} \;
}

# Fungsi instalasi utama
install_wordpress() {
    # Tampilkan pesan selamat datang
    echo -e "\n${HIJAU}=== Skrip Instalasi WordPress ===${NC}"
    echo -e "Skrip ini akan menginstal WordPress dengan Nginx, MariaDB, dan PHP 8.4\n"
    
    # Meminta input domain
    while true; do
        read -p "Masukkan domain Anda (contoh: contoh.com): " domain
        if validate_domain "$domain"; then
            break
        fi
    done
    
    # Meminta detail database
    read -p "Masukkan nama database: " dbname
    read -p "Masukkan username database: " dbuser
    while true; do
        read -s -p "Masukkan password database: " dbpass
        echo
        if [ -z "$dbpass" ]; then
            echo -e "${MERAH}Error: Password tidak boleh kosong${NC}"
        else
            break
        fi
    done
    
    # Update sistem
    echo -e "\n${BIRU}Memperbarui daftar paket...${NC}"
    sudo apt-get update > /dev/null
    
    # Aktifkan dan konfigurasi UFW
    echo -e "\n${BIRU}Mengkonfigurasi firewall UFW...${NC}"
    sudo ufw --force enable > /dev/null
    sudo ufw allow ssh > /dev/null
    sudo ufw allow 'Nginx Full' > /dev/null
    
    # Instal paket yang diperlukan
    install_with_progress nginx mariadb-server php8.4-fpm php8.4-common php8.4-mysql php8.4-gd php8.4-mbstring php8.4-xml php8.4-curl php8.4-zip php8.4-bcmath php8.4-soap php8.4-intl php8.4-imagick fail2ban certbot python3-certbot-nginx
    
    # Konfigurasi MariaDB
    echo -e "\n${BIRU}Mengkonfigurasi MariaDB...${NC}"
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${dbname};"
    sudo mysql -e "CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    
    # Download dan ekstrak WordPress
    echo -e "\n${BIRU}Mengunduh WordPress...${NC}"
    sudo mkdir -p /var/www/${domain} > /dev/null
    cd /var/www/${domain}
    sudo wget -q https://wordpress.org/latest.tar.gz
    sudo tar -xzf latest.tar.gz
    sudo rm latest.tar.gz
    
    # Konfigurasi WordPress
    configure_wordpress "$domain" "$dbname" "$dbuser" "$dbpass"
    
    # Setup SSL
    setup_ssl "$domain"
    
    # Buat konfigurasi Nginx
    echo -e "\n${BIRU}Membuat konfigurasi Nginx...${NC}"
    sudo tee /etc/nginx/sites-available/${domain} > /dev/null <<EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    
    server_name ${domain} www.${domain};
    
    ssl_certificate /etc/ssl/${domain}/cert.pem;
    ssl_certificate_key /etc/ssl/${domain}/key.pem;
    
    root /var/www/${domain}/wordpress;
    index index.php index.html index.htm;
    
    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log;
    
    client_max_body_size 100M;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    location ~ /\.ht {
        deny all;
    }
    
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires max;
        log_not_found off;
    }
    
    # Header keamanan
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
}
EOF
    
    # Aktifkan situs
    sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/ > /dev/null
    
    # Test dan reload Nginx
    echo -e "\n${BIRU}Menguji konfigurasi Nginx...${NC}"
    if sudo nginx -t > /dev/null 2>&1; then
        sudo systemctl reload nginx > /dev/null
        echo -e "${HIJAU}✓ Konfigurasi Nginx valid dan berhasil di-reload${NC}"
    else
        echo -e "${MERAH}Error dalam konfigurasi Nginx${NC}"
        exit 1
    fi
    
    # Konfigurasi Fail2Ban untuk WordPress
    echo -e "\n${BIRU}Mengkonfigurasi Fail2Ban untuk WordPress...${NC}"
    sudo tee /etc/fail2ban/filter.d/wordpress.conf > /dev/null <<EOF
[Definition]
failregex = ^<HOST> .* "POST .*/wp-login.php HTTP/.*" 200
ignoreregex =
EOF
    
    sudo tee /etc/fail2ban/jail.d/wordpress.conf > /dev/null <<EOF
[wordpress]
enabled = true
port = http,https
filter = wordpress
logpath = /var/log/nginx/${domain}.error.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
    
    sudo systemctl restart fail2ban > /dev/null
    
    # Tampilkan pesan penyelesaian
    echo -e "\n${HIJAU}=== Instalasi WordPress Selesai ===${NC}"
    echo -e "URL Website: https://${domain}"
    echo -e "URL Admin: https://${domain}/wp-admin"
    echo -e "Nama Database: ${dbname}"
    echo -e "User Database: ${dbuser}"
    echo -e "\n${KUNING}Harap selesaikan setup WordPress dengan mengunjungi URL admin.${NC}"
}

# Cek apakah skrip dijalankan sebagai root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${MERAH}Skrip ini harus dijalankan sebagai root atau dengan hak akses sudo.${NC}"
    exit 1
fi

# Cek apakah berjalan di Ubuntu 22.04
if [ "$(lsb_release -rs)" != "22.04" ]; then
    echo -e "${MERAH}Skrip ini hanya untuk Ubuntu 22.04.${NC}"
    exit 1
fi

# Cek apakah akan menginstal situs lain
while true; do
    install_wordpress
    
    read -p "Apakah Anda ingin menginstal situs WordPress lain? (y/n): " another
    if [[ ! "$another" =~ ^[Yy] ]]; then
        break
    fi
done

echo -e "\n${HIJAU}Semua instalasi berhasil diselesaikan!${NC}"