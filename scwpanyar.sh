#!/bin/bash

BIRU_TUA='\033[0;34m'
BIRU_MUDA='\033[1;36m'
HIJAU='\033[0;32m'
KUNING='\033[1;33m'
MERAH='\033[0;31m'
NC='\033[0m'

tampilkan_header() {
    clear
    echo -e "${BIRU_TUA}"
    echo "============================================================"
    echo "                      ishowpen                               "
    echo "============================================================"
    echo -e "${NC}"
    echo -e "${KUNING}Pemasangan WordPress Otomatis${NC}"
}

pesan_status() {
    echo -e "${BIRU_TUA}[STATUS] $1${NC}"
}

pesan_sukses() {
    echo -e "${HIJAU}[SUKSES] $1${NC}"
}

pesan_peringatan() {
    echo -e "${KUNING}[PERINGATAN] $1${NC}"
}

pesan_kesalahan() {
    echo -e "${MERAH}[KESALAHAN] $1${NC}" >&2
}

pasang_paket() {
    sudo apt-get update > /dev/null
    sudo apt-get install -y "$@" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        pesan_sukses "Paket berhasil dipasang"
        return 0
    else
        pesan_kesalahan "Gagal memasang paket"
        return 1
    fi
}

validasi_domain() {
    local regex_domain='^([a-zA-Z0-9][a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$'
    [[ $1 =~ $regex_domain ]] && return 0
    pesan_kesalahan "Format domain tidak valid: $1"
    return 1
}

hasilkan_kredensial_db() {
    db_name="wp_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    db_user="wp_user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    db_pass=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+' < /dev/urandom | head -c 32)
    echo -e "\n${HIJAU}Kredensial database:${NC}"
    echo -e "Database: ${BIRU_MUDA}$db_name${NC}"
    echo -e "Pengguna: ${BIRU_MUDA}$db_user${NC}"
    echo -e "Kata Sandi: ${BIRU_MUDA}$db_pass${NC}\n"
}

konfigurasi_php() {
    local php_ini="/etc/php/8.1/fpm/php.ini"
    sudo cp $php_ini "$php_ini.bak"
    declare -A settings=(
        ["max_execution_time"]="180"
        ["memory_limit"]="256M"
        ["upload_max_filesize"]="128M"
        ["post_max_size"]="160M"
        ["max_input_vars"]="5000"
        ["opcache.enable"]="1"
        ["opcache.memory_consumption"]="256"
        ["opcache.interned_strings_buffer"]="32"
        ["opcache.max_accelerated_files"]="20000"
        ["opcache.validate_timestamps"]="0"
        ["opcache.save_comments"]="1"
        ["max_input_time"]="180"
    )
    for key in "${!settings[@]}"; do
        sudo sed -i "s/^;*$key\s*=.*/$key = ${settings[$key]}/" $php_ini
    done
    sudo sed -i "s/^;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/" $php_ini
    sudo sed -i "s/^expose_php=.*/expose_php=Off/" $php_ini
    sudo systemctl restart php8.1-fpm
    pesan_sukses "PHP 8.1 dioptimasi"
}

konfigurasi_mariadb() {
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mysql -e "CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    pesan_sukses "Database dibuat"
}

pasang_file_wordpress() {
    sudo mkdir -p /var/www/$1
    cd /var/www/$1
    sudo wget -q https://id.wordpress.org/latest-id_ID.tar.gz
    sudo tar xzf latest-id_ID.tar.gz --strip-components=1
    sudo rm latest-id_ID.tar.gz
    sudo chown -R www-data:www-data .
    sudo find . -type d -exec chmod 755 {} \;
    sudo find . -type f -exec chmod 644 {} \;
    sudo mkdir -p wp-content/uploads
    sudo chmod 775 wp-content/uploads
    pesan_sukses "WordPress terpasang"
}

konfigurasi_wp_config() {
    cd /var/www/$1
    sudo cp wp-config-sample.php wp-config.php
    sudo sed -i "s/database_name_here/$db_name/" wp-config.php
    sudo sed -i "s/username_here/$db_user/" wp-config.php
    sudo sed -i "s/password_here/$db_pass/" wp-config.php
    sudo curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> wp-config.php
    cat << 'EOF' | sudo tee -a wp-config.php > /dev/null
define('DISALLOW_FILE_EDIT', true);
define('FORCE_SSL_ADMIN', true);
define('WP_AUTO_UPDATE_CORE', 'minor');
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '256M');
define('WP_CACHE', true);
define('WP_DEBUG', false);
define('WP_HOME', 'https://$domain');
define('WP_SITEURL', 'https://$domain');
define('RANK_MATH_DEBUG', false);
define('RELEVANSSI_HIGHLIGHT', true);
define('POST_VIEWS_COUNTER_DEBUG', false);
define('FM_DISABLE_OVERWRITE', true);
function set_permalink_structure() {
    global $wp_rewrite;
    $wp_rewrite->set_permalink_structure('/%postname%/');
    $wp_rewrite->flush_rules();
}
add_action('init', 'set_permalink_structure');
EOF
    sudo sed -i "s/\$domain/$1/" wp-config.php
    pesan_sukses "wp-config dioptimasi"
}

pasang_ssl() {
    case $1 in
        1)
            sudo certbot --nginx -d $2 -d www.$2 --non-interactive --agree-tos --email admin@$2 > /dev/null 2>&1 || \
            sudo certbot certonly --standalone -d $2 -d www.$2 --non-interactive --agree-tos --email admin@$2
            (sudo crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\"") | sudo crontab -
            pesan_sukses "SSL Let's Encrypt terpasang"
            ;;
        2)
            sudo mkdir -p /etc/ssl/$2
            echo -e "${KUNING}Buat file SSL di /etc/ssl/$2 (key.pem dan cert.pem), lalu tekan Enter...${NC}"
            read
            if [[ ! -f /etc/ssl/$2/key.pem ]]; then
                pesan_kesalahan "File SSL tidak ada, gunakan self-signed"
                pasang_ssl 3 $2
            fi
            ;;
        3)
            sudo mkdir -p /etc/ssl/$2
            sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout /etc/ssl/$2/key.pem -out /etc/ssl/$2/cert.pem \
                -subj "/CN=$2" > /dev/null 2>&1
            pesan_sukses "SSL Self-Signed dibuat"
            ;;
        *)
            pasang_ssl 1 $2
            ;;
    esac
}

buat_konfigurasi_nginx() {
    local ssl_cert="/etc/letsencrypt/live/$1/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/$1/privkey.pem"
    
    if [[ $2 -eq 2 ]]; then
        ssl_cert="/etc/ssl/$1/cert.pem"
        ssl_key="/etc/ssl/$1/key.pem"
    elif [[ $2 -eq 3 ]]; then
        ssl_cert="/etc/ssl/$1/cert.pem"
        ssl_key="/etc/ssl/$1/key.pem"
    fi
    
    sudo tee /etc/nginx/sites-available/$1 > /dev/null <<EOF
server {
    listen 80;
    server_name $1 www.$1;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $1 www.$1;
    root /var/www/$1;
    index index.php;
    ssl_certificate $ssl_cert;
    ssl_certificate_key $ssl_key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht {
        deny all;
    }
    location ~* /(wp-config\.php|\.env) {
        deny all;
    }
    location = /xmlrpc.php {
        deny all;
        return 444;
    }
    location ~* ^/(instant-indexing|search|relevanssi) {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~* ^/wp-content/plugins/wp-file-manager/lib/files/.*\.(php|php5|phtml)\$ {
        deny all;
    }
}
server {
    listen 443 ssl http2;
    server_name www.$1;
    return 301 https://$1\$request_uri;
}
EOF
    sudo ln -s /etc/nginx/sites-available/$1 /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl reload nginx
    pesan_sukses "Nginx dikonfigurasi"
}

pasang_wordpress() {
    tampilkan_header
    while true; do
        read -p "Masukkan domain: " domain
        validasi_domain "$domain" && break
    done
    
    echo -e "\n${BIRU_MUDA}Pilihan database:"
    echo "1) Kredensial otomatis"
    echo "2) Kredensial manual"
    read -p "Pilihan [1-2]: " pilihan_db
    
    if [ "$pilihan_db" = "1" ]; then
        hasilkan_kredensial_db
    else
        read -p "Nama database: " db_name
        read -p "Pengguna database: " db_user
        read -sp "Kata sandi database: " db_pass
        echo
    fi
    
    pesan_status "Memulai instalasi sistem..."
    pasang_paket nginx mariadb-server software-properties-common
    sudo add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
    sudo apt update > /dev/null
    pasang_paket php8.1-fpm php8.1-common php8.1-mysql php8.1-gd php8.1-mbstring \
        php8.1-xml php8.1-curl php8.1-zip php8.1-bcmath php8.1-soap php8.1-intl \
        php8.1-imagick certbot python3-certbot-nginx
    
    konfigurasi_php
    konfigurasi_mariadb
    pasang_file_wordpress "$domain"
    konfigurasi_wp_config "$domain"
    
    echo -e "\n${KUNING}Pilih SSL:"
    echo "1) Let's Encrypt"
    echo "2) Cloudflare"
    echo "3) Self-Signed"
    read -p "Pilihan [1-3]: " pilihan_ssl
    
    pasang_ssl "$pilihan_ssl" "$domain"
    buat_konfigurasi_nginx "$domain" "$pilihan_ssl"
    
    echo -e "\n${KUNING}Pasang Redis untuk caching? [y/n]:${NC}"
    read -p "Pilihan: " redis_choice
    if [[ "$redis_choice" =~ ^[Yy] ]]; then
        pasang_paket redis-server php-redis
        cat << 'EOF' | sudo tee -a /var/www/$domain/wp-config.php > /dev/null
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_REDIS_DATABASE', 0);
EOF
        pesan_sukses "Redis terpasang"
    fi
    
    tampilkan_header
    echo -e "${HIJAU}INSTALASI SELESAI!${NC}"
    echo -e "\nURL: https://$domain"
    echo "Admin: https://$domain/wp-admin"
    echo -e "\nDatabase: $db_name"
    echo "Pengguna: $db_user"
    echo "Password: $db_pass"
    echo -e "\n${KUNING}Langkah selanjutnya:"
    echo "1. Selesaikan setup WordPress"
    echo "2. Pasang plugin yang direkomendasikan"
    if [ "$pilihan_ssl" = "2" ]; then
        echo -e "\nAtur Cloudflare:"
        echo "- Mode SSL: Full (Strict)"
        echo "- Always Use HTTPS: Aktif"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${MERAH}Jalankan sebagai root!${NC}" >&2
    exit 1
fi

if ! lsb_release -i | grep -q "Ubuntu"; then
    echo -e "${MERAH}Hanya untuk Ubuntu!${NC}" >&2
    exit 1
fi

pasang_wordpress

while true; do
    echo -e "\n${KUNING}Instal situs lain? [y/n]:${NC}"
    read -p "Pilihan: " lagi
    [[ "$lagi" =~ ^[Yy] ]] || break
    pasang_wordpress
done

echo -e "\n${HIJAU}Semua instalasi selesai!${NC}"