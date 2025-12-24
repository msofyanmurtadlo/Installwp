#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root."
    exit 1
fi

C_RESET='\e[0m'
C_RED='\e[1;31m'
C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m'
C_BLUE='\e[1;34m'
C_MAGENTA='\e[1;35m'
C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

readonly password_file="mariadb_root_pass.txt"
declare -g mariadb_unified_pass
declare -g OS_ID OS_CODENAME PHP_VERSION PRETTY_NAME

log() {
    local type=$1
    local msg=$2
    case "$type" in
        "info") echo -e "${C_BLUE}INFO:${C_RESET} $msg" ;;
        "success") echo -e "${C_GREEN}SUKSES:${C_RESET} $msg" ;;
        "warn") echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $msg" ;;
        "error") echo -e "${C_RED}ERROR:${C_RESET} $msg${C_RESET}"; exit 1 ;;
        "header") echo -e "\n${C_BOLD}${C_MAGENTA}--- $msg ---${C_RESET}" ;;
    esac
}

run_task() {
    local description=$1
    shift
    local command_args=("$@")
    printf "${C_CYAN}   -> %s... ${C_RESET}" "$description"
    output=$("${command_args[@]}" 2>&1)
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${C_GREEN}[OK]${C_RESET}"
        return 0
    else
        echo -e "${C_RED}[GAGAL]${C_RESET}"
        echo -e "$output" >&2
        return $exit_code
    fi
}

detect_os_php() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID=$ID
        OS_CODENAME=$VERSION_CODENAME
        PRETTY_NAME=$PRETTY_NAME
        [[ "$OS_ID" != "ubuntu" ]] && log "error" "Skrip ini hanya untuk Ubuntu."
    else
        log "error" "Gagal mendeteksi OS."
    fi
    case "$OS_CODENAME" in
        "noble") PHP_VERSION="8.3" ;;
        "jammy") PHP_VERSION="8.1" ;;
        "focal") PHP_VERSION="7.4" ;;
        *) PHP_VERSION="Tidak Didukung" ;;
    esac
}

prompt_input() {
    local message=$1
    local var_name=$2
    local is_secret=false
    [[ "$3" == "-s" ]] && is_secret=true
    local prompt_text="${C_CYAN}❓ ${message}:${C_RESET} "
    while true; do
        local user_input
        printf "%b" "$prompt_text"
        if $is_secret; then read -s user_input; echo; else read user_input; fi
        user_input_sanitized="${user_input// /}"
        if [[ -n "$user_input_sanitized" ]]; then
            eval "$var_name"="'$user_input_sanitized'"
            break
        else
            echo -e "${C_RED}Input tidak boleh kosong.${C_RESET}"
        fi
    done
}

load_or_create_password() {
    if [ -s "$password_file" ]; then
        mariadb_unified_pass=$(cat "$password_file")
    else
        log "header" "KONFIGURASI KATA SANDI MARIADB"
        prompt_input "Kata sandi baru untuk MariaDB root" mariadb_unified_pass -s
        echo "$mariadb_unified_pass" > "$password_file"
        chmod 600 "$password_file"
    fi
}

setup_cloudflare_real_ip() {
    log "info" "Konfigurasi Real IP Cloudflare..."
    cat <<EOF > /etc/nginx/conf.d/cloudflare.conf
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;
EOF
}

setup_fail2ban() {
    log "info" "Konfigurasi Fail2Ban..."
    cat <<EOF > /etc/fail2ban/filter.d/wordpress.conf
[Definition]
failregex = ^<HOST>.* "POST /wp-login.php
            ^<HOST>.* "POST /xmlrpc.php
ignoreregex =
EOF
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 5
banaction = ufw
backend = auto

[sshd]
enabled = true

[wordpress]
enabled = true
port = http,https
filter = wordpress
logpath = /var/log/nginx/*/access.log
          /var/log/nginx/access.log
maxretry = 3
EOF
    systemctl stop fail2ban
    rm -f /var/run/fail2ban/fail2ban.sock
    systemctl start fail2ban
    systemctl enable fail2ban
}

setup_server() {
    log "header" "MEMULAI SETUP SERVER"
    detect_os_php
    run_task "Update paket" apt-get update -y
    run_task "Install dependensi" apt-get install -y software-properties-common curl wget unzip fail2ban ufw mariadb-server nginx bc
    
    if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -y
    fi

    local php_packages=("php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath")
    run_task "Install PHP $PHP_VERSION" apt-get install -y "${php_packages[@]}"
    
    if ! command -v wp &> /dev/null; then
        wget -qO /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x /usr/local/bin/wp
    fi

    load_or_create_password
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; FLUSH PRIVILEGES;" 2>/dev/null

    ufw allow 'OpenSSH'
    ufw allow 'Nginx Full'
    ufw --force enable
    
    setup_cloudflare_real_ip
    setup_fail2ban
    
    nginx -t && systemctl restart nginx
    log "success" "Setup server selesai!"
}

add_website() {
    log "header" "TAMBAH WEBSITE"
    load_or_create_password
    prompt_input "Domain" domain
    local web_root="/var/www/$domain/public_html"
    local dbname="${domain//./_}_wp"
    local dbuser="${domain//./_}_usr"
    local log_dir="/var/log/nginx/$domain"

    mysql -u root -p"$mariadb_unified_pass" -e "CREATE DATABASE $dbname; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; FLUSH PRIVILEGES;"

    mkdir -p "$web_root" "$log_dir"
    chown -R www-data:www-data "/var/www/$domain"
    
    sudo -u www-data wp core download --path="$web_root"
    sudo -u www-data wp config create --path="$web_root" --dbname="$dbname" --dbuser="$dbuser" --dbpass="$mariadb_unified_pass"

    log "info" "Konfigurasi SSL"
    local cert="/etc/nginx/ssl/$domain/$domain.crt"
    local key="/etc/nginx/ssl/$domain/$domain.key"
    mkdir -p "$(dirname "$cert")"
    prompt_input "ENTER untuk isi CRT" junk && nano "$cert"
    prompt_input "ENTER untuk isi KEY" junk && nano "$key"

    tee "/etc/nginx/sites-enabled/$domain" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain www.$domain;
    root $web_root;
    index index.php;
    access_log $log_dir/access.log;
    error_log $log_dir/error.log;
    ssl_certificate $cert;
    ssl_certificate_key $key;
    rewrite ^/sitemap\.xml$ /index.php?sitemap=1 last;
    rewrite ^/sitemap_index\.xml$ /index.php?sitemap=1 last;
    rewrite ^/([^/]+?)-sitemap([0-9]+)?\.xml$ /index.php?sitemap=\$1&sitemap_n=\$2 last;
    rewrite ^/([a-z]+)?-sitemap\.xsl$ /index.php?xsl=\$1 last;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    client_max_body_size 100M;
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_comp_level 5;
    gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;
    gzip_proxied any;
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location = /xmlrpc.php { deny all; access_log off; }
    location ~* /wp-config\.php { deny all; }
    location ~* /(?:uploads|files)/.*\.php$ { deny all; }
    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
       access_log off;
       log_not_found off;
       expires 360d;
    }
    location ~ /\.ht { deny all; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_buffers 1024 4k;
        fastcgi_buffer_size 128k;
    }
}
EOF
    nginx -t && systemctl reload nginx && systemctl reload fail2ban
    
    log "header" "INSTALL WORDPRESS"
    local site_title admin_user admin_password admin_email
    prompt_input "Judul Website" site_title
    prompt_input "Username Admin" admin_user
    prompt_input "Password Admin" admin_password -s
    prompt_input "Email Admin" admin_email
    
    sudo -u www-data wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email"
    
    log "info" "Mengelola Plugin Kustom..."
    local plugin_url="https://github.com/sofyanmurtadlo10/wp/raw/main/plugin.zip"
    local plugin_zip="/tmp/plugin.zip"
    local plugin_dir="$web_root/wp-content/plugins"
    
    run_task "Download paket plugin" wget -qO "$plugin_zip" "$plugin_url"
    run_task "Ekstrak plugin" unzip -o "$plugin_zip" -d "$plugin_dir"
    rm -f "$plugin_zip"
    
    run_task "Aktivasi plugin standar" sudo -u www-data wp plugin install wp-file-manager disable-comments-rb floating-ads-bottom post-views-counter seo-by-rank-math --activate --path="$web_root"
    run_task "Aktivasi semua plugin kustom" sudo -u www-data wp plugin activate --all --path="$web_root"
    
    log "success" "$domain siap!"
}

list_websites() {
    log "header" "DAFTAR WEBSITE"
    ls -A /etc/nginx/sites-enabled/ | grep -v "default"
}

update_semua_situs() {
    log "header" "UPDATE SEMUA SITUS"
    for nginx_conf in /etc/nginx/sites-enabled/*; do
        domain=$(basename "$nginx_conf")
        [[ "$domain" == "default" ]] && continue
        web_root=$(grep -oP '^\s*root\s+\K[^;]+' "$nginx_conf" | head -n 1)
        if [ -f "$web_root/wp-config.php" ]; then
            sudo -u www-data wp core update --path="$web_root"
            sudo -u www-data wp plugin update --all --path="$web_root"
        fi
    done
}

delete_website() {
    log "header" "HAPUS WEBSITE"
    prompt_input "Domain" domain
    rm "/etc/nginx/sites-enabled/$domain"
    rm -rf "/var/www/$domain"
    rm -rf "/etc/nginx/ssl/$domain"
    rm -rf "/var/log/nginx/$domain"
    systemctl reload nginx
    log "success" "$domain dihapus."
}

show_menu() {
    clear
    echo "=========================================================="
    echo "          🚀 SCRIPT MANAJEMEN WORDPRESS 🚀                "
    echo "=========================================================="
    echo " 1. Setup Server & Fail2Ban"
    echo " 2. Tambah Website WordPress"
    echo " 3. Lihat Daftar Website"
    echo " 4. Update Semua Situs"
    echo " 5. Hapus Website"
    echo " 6. Keluar"
}

main() {
    while true; do
        show_menu
        read -p "Pilih [1-6]: " choice
        case $choice in
            1) setup_server ;;
            2) add_website ;;
            3) list_websites ;;
            4) update_semua_situs ;;
            5) delete_website ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
        read -n 1 -s -r -p "Tekan ENTER untuk kembali..."
    done
}

detect_os_php
main