#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "❌ Kesalahan: Skrip ini harus dijalankan sebagai root. Coba 'sudo bash $0'"
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
        echo -e "${C_RED}==================== DETAIL ERROR ====================${C_RESET}" >&2
        echo -e "$output" >&2
        echo -e "${C_RED}====================================================${C_RESET}" >&2
        return $exit_code
    fi
}

detect_os_php() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID=$ID
        OS_CODENAME=$VERSION_CODENAME
        PRETTY_NAME=$PRETTY_NAME
        if [[ "$OS_ID" != "ubuntu" ]]; then
            log "error" "Skrip ini dioptimalkan untuk Ubuntu. OS terdeteksi: $OS_ID."
        fi
    else
        log "error" "Tidak dapat mendeteksi sistem operasi."
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
    if [[ "$3" == "-s" ]]; then
        is_secret=true
    fi

    local prompt_text="${C_CYAN}❓ ${message}:${C_RESET} "
    
    while true; do
        local user_input
        printf "%b" "$prompt_text"
        if $is_secret; then
            read -s user_input
            echo
        else
            read user_input
        fi
        
        user_input_sanitized="${user_input// /}"

        if [[ -n "$user_input_sanitized" ]]; then
            eval "$var_name"="'$user_input_sanitized'"
            break
        else
            echo -e "${C_RED}Input tidak boleh kosong. Silakan coba lagi.${C_RESET}"
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
        log "success" "Kata sandi berhasil disimpan ke '$password_file'."
    fi
}

# --- LOGIC BARU: CLOUDFLARE REAL IP ---
setup_cloudflare_real_ip() {
    log "info" "Mengonfigurasi Real IP Cloudflare untuk Nginx..."
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

# --- LOGIC BARU: FAIL2BAN ---
setup_fail2ban_logic() {
    log "info" "Mengonfigurasi Fail2Ban untuk SSH dan WordPress..."
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
}

setup_server() {
    log "header" "MEMULAI SETUP SERVER"
    log "info" "Menggunakan OS terdeteksi: $PRETTY_NAME"
    detect_os_php
    if [[ "$PHP_VERSION" == "Tidak Didukung" ]]; then
        log "error" "Versi Ubuntu '$OS_CODENAME' tidak didukung secara otomatis oleh skrip ini."
    fi
    log "success" "Versi PHP yang akan digunakan untuk $OS_CODENAME: PHP $PHP_VERSION"

    run_task "Memperbarui daftar paket" apt-get update -y --allow-releaseinfo-change || log "error" "Gagal memperbarui paket."

    if ! dpkg -s software-properties-common &> /dev/null; then
        run_task "Menginstal software-properties-common" apt-get install -y software-properties-common || log "error"
    fi

    if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        log "info" "Menambahkan PPA PHP dari Ondrej Sury..."
        run_task "Menambahkan PPA ondrej/php" add-apt-repository -y ppa:ondrej/php || log "error"
        run_task "Memperbarui daftar paket lagi" apt-get update -y --allow-releaseinfo-change || log "error"
    fi

    local core_packages=(nginx mariadb-server mariadb-client unzip curl wget fail2ban bc ufw)
    local php_packages=(
        "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" 
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-zip" 
        "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath"
    )
    local packages_needed=("${core_packages[@]}" "${php_packages[@]}")
    
    run_task "Menginstal paket yang dibutuhkan" apt-get install -y "${packages_needed[@]}" || log "error"

    if ! command -v wp &> /dev/null; then
        run_task "Menginstal WP-CLI" wget -qO /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x /usr/local/bin/wp || log "error"
    fi

    run_task "Memulai layanan MariaDB" systemctl enable --now mariadb.service || log "error"
    load_or_create_password
    run_task "Mengatur User Root MariaDB" mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; FLUSH PRIVILEGES;" 2>/dev/null || mysql -u root -p"$mariadb_unified_pass" -e "SELECT 1;"

    if ! ufw status | grep -q "Status: active"; then
        run_task "Mengizinkan OpenSSH" ufw allow 'OpenSSH'
        run_task "Mengizinkan Nginx Full" ufw allow 'Nginx Full'
        run_task "Mengaktifkan Firewall" ufw --force enable
    fi

    setup_cloudflare_real_ip
    setup_fail2ban_logic
    
    run_task "Restarting Services" systemctl restart nginx fail2ban
    
    log "success" "Setup server selesai! Versi PHP aktif: $PHP_VERSION."
}

generate_db_credentials() {
    local domain=$1
    local suffix=$2
    local domain_part
    domain_part=$(echo "$domain" | tr '.' '_' | cut -c1-10)
    local hash_part
    hash_part=$(echo -n "$domain" | md5sum | cut -c1-5)
    echo "${domain_part}_${hash_part}${suffix}"
}

add_website() {
    if [[ "$PHP_VERSION" == "Tidak Didukung" ]]; then
        log "error" "Tidak dapat menambah website karena versi Ubuntu '$OS_CODENAME' tidak didukung."
    fi

    log "header" "TAMBAH WEBSITE WORDPRESS BARU"
    load_or_create_password
    local domain web_root dbname dbuser
    
    prompt_input "Nama domain (contoh: domainanda.com)" domain
    
    web_root="/var/www/$domain/public_html"
    dbname=$(generate_db_credentials "$domain" "_wp")
    dbuser=$(generate_db_credentials "$domain" "_usr")

    if [ -f "/etc/nginx/sites-enabled/$domain" ]; then
        log "error" "Konflik: File konfigurasi Nginx untuk $domain sudah ada di sites-enabled."
    fi

    run_task "Membuat database '$dbname' dan user '$dbuser'" mysql -u root -p"$mariadb_unified_pass" -e "CREATE DATABASE $dbname; CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;" || log "error"
    
    run_task "Membuat direktori root dan mengatur izin" mkdir -p "$web_root" && chown -R www-data:www-data "/var/www/$domain" || log "error"
    
    run_task "Mengunduh file inti WordPress" sudo -u www-data wp core download --path="$web_root" || log "error"
    run_task "Membuat file wp-config.php" sudo -u www-data wp config create --path="$web_root" --dbname="$dbname" --dbuser="$dbuser" --dbpass="$mariadb_unified_pass" || log "error"

    log "header" "KONFIGURASI SSL (HTTPS)"
    local ssl_dir="/etc/nginx/ssl/$domain"
    run_task "Membuat direktori SSL" mkdir -p "$ssl_dir" || log "error"
    local ssl_cert_path="$ssl_dir/$domain.crt"
    local ssl_key_path="$ssl_dir/$domain.key"
    
    log "info" "Selanjutnya, editor teks 'nano' akan terbuka untuk Anda."
    echo -e "${C_YELLOW}   -> Tempelkan konten sertifikat (.crt), lalu simpan (Ctrl+X, Y, Enter).${C_RESET}"
    read -p "   Tekan ENTER untuk melanjutkan..."
    nano "$ssl_cert_path"
    
    echo -e "${C_YELLOW}   -> Tempelkan konten Kunci Privat (.key), lalu simpan.${C_RESET}"
    read -p "   Tekan ENTER untuk melanjutkan..."
    nano "$ssl_key_path"

    if [ ! -s "$ssl_cert_path" ] || [ ! -s "$ssl_key_path" ]; then log "error" "File SSL tidak boleh kosong."; fi

    local log_dir="/var/log/nginx/$domain"
    run_task "Membuat direktori log Nginx" mkdir -p "$log_dir" || log "error"

    log "info" "Membuat file konfigurasi Nginx untuk '$domain' langsung di sites-enabled..."
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

    ssl_certificate $ssl_cert_path;
    ssl_certificate_key $ssl_key_path;

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

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~* /wp-config\.php { deny all; }
    location = /xmlrpc.php { deny all; access_log off; }

    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
       access_log         off;
       log_not_found      off;
       expires            360d;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_buffers 1024 4k;
        fastcgi_buffer_size 128k;
    }
}
EOF

    if ! run_task "Menguji konfigurasi Nginx" nginx -t; then
        log "error" "Konfigurasi Nginx tidak valid."
    fi
    run_task "Me-reload layanan Nginx" systemctl reload nginx || log "error"
    systemctl reload fail2ban

    log "header" "INFORMASI ADMIN WORDPRESS"
    log "info" "Silakan masukkan detail untuk akun admin WordPress."
    local site_title admin_user admin_password admin_email
    
    prompt_input "Judul Website" site_title
    prompt_input "Username Admin" admin_user
    prompt_input "Password Admin" admin_password -s
    prompt_input "Email Admin" admin_email
    
    run_task "Menjalankan instalasi WordPress" sudo -u www-data wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email" || log "error"
    
    run_task "Menghapus plugin bawaan" sudo -u www-data wp plugin delete hello akismet --path="$web_root"

    log "info" "Menginstal plugin-plugin standar..."
    run_task "Menginstal plugin" sudo -u www-data wp plugin install wp-file-manager disable-comments-rb floating-ads-bottom post-views-counter seo-by-rank-math --activate --path="$web_root" || log "error"

    log "info" "Mengunduh dan mengekstrak paket plugin kustom..."
    local plugin_url="https://github.com/sofyanmurtadlo10/wp/blob/main/plugin.zip?raw=true"
    local plugin_zip="/tmp/plugin_paket.zip"
    local plugin_dir="$web_root/wp-content/plugins/"
    
    run_task "Mengunduh plugin zip" wget -qO "$plugin_zip" "$plugin_url" || log "error" "Gagal mengunduh paket plugin."
    run_task "Mengekstrak plugin" sudo -u www-data unzip -o "$plugin_zip" -d "$plugin_dir" || log "error"
    run_task "Aktivasi semua plugin" sudo -u www-data wp plugin activate --all --path="$web_root" || log "error"
    run_task "Membersihkan file zip" rm "$plugin_zip" || log "warn" "Gagal menghapus file zip sementara."

    log "success" "Situs https://$domain selesai!"
}

list_websites() {
    log "header" "DAFTAR WEBSITE TERPASANG"
    local sites_dir="/etc/nginx/sites-enabled"
    if [ -d "$sites_dir" ] && [ -n "$(ls -A "$sites_dir")" ]; then
        for site in "$sites_dir"/*; do
            if [[ "$(basename "$site")" != "default" ]]; then
                echo -e "    🌐 ${C_GREEN}$(basename "$site")${C_RESET}"
            fi
        done
    else
        log "warn" "Tidak ada website yang ditemukan."
    fi
}

update_semua_situs() {
    log "header" "MEMPERBARUI WORDPRESS CORE, PLUGIN & TEMA"
    local sites_dir="/etc/nginx/sites-enabled"
    for nginx_conf in "$sites_dir"/*; do
        local domain=$(basename "$nginx_conf")
        [[ "$domain" == "default" ]] && continue
        local web_root=$(grep -oP '^\s*root\s+\K[^;]+' "$nginx_conf" | head -n 1)
        if [ -f "$web_root/wp-config.php" ]; then
            echo -e "\n🔎 Memproses situs: $domain"
            run_task "Update Core" sudo -u www-data wp core update --path="$web_root"
            run_task "Update Plugins" sudo -u www-data wp plugin update --all --path="$web_root"
        fi
    done
}

delete_website() {
    log "header" "HAPUS WEBSITE"
    local domain
    prompt_input "Nama domain yang akan dihapus" domain
    local nginx_conf="/etc/nginx/sites-enabled/$domain"
    local ssl_dir="/etc/nginx/ssl/$domain"
    local log_dir="/var/log/nginx/$domain"
    local web_root_parent

    if [ -f "$nginx_conf" ]; then
        local public_html_path=$(grep -oP '^\s*root\s+\K[^;]+' "$nginx_conf" | head -n 1)
        [ -n "$public_html_path" ] && web_root_parent=$(dirname "$public_html_path")
    fi

    [ -z "$web_root_parent" ] && web_root_parent="/var/www/$domain"
    
    local dbname=$(generate_db_credentials "$domain" "_wp")
    local dbuser=$(generate_db_credentials "$domain" "_usr")

    read -p "❓ Hapus semua data domain $domain? (y/N): " confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then return; fi

    run_task "Hapus Nginx conf" rm "$nginx_conf"
    run_task "Hapus Web Root" rm -rf "$web_root_parent"
    run_task "Hapus SSL & Log" rm -rf "$ssl_dir" "$log_dir"
    run_task "Reload Nginx" systemctl reload nginx

    load_or_create_password
    run_task "Hapus DB" mysql -u root -p"$mariadb_unified_pass" -e "DROP DATABASE IF EXISTS $dbname; DROP USER IF EXISTS '$dbuser'@'localhost'; FLUSH PRIVILEGES;"
    log "success" "Selesai dihapus."
}

show_menu() {
    clear
    echo -e "${C_BOLD}${C_MAGENTA}==========================================================${C_RESET}"
    echo -e "${C_BOLD}${C_MAGENTA}          🚀 SCRIPT MANAJEMEN WORDPRESS SUPER 🚀          ${C_RESET}"
    echo -e "${C_BOLD}${C_MAGENTA}==========================================================${C_RESET}"
    echo -e "  OS: ${C_CYAN}${PRETTY_NAME}${C_RESET} | PHP: ${C_CYAN}${PHP_VERSION}${C_RESET}"
    echo ""
    echo "  1. Setup Awal Server & Fail2Ban"
    echo "  2. Tambah Website WordPress"
    echo "  3. Lihat Daftar Website"
    echo "  4. Perbarui Semua Situs"
    echo "  5. Hapus Website"
    echo "  6. Keluar"
}

main() {
    while true; do
        show_menu
        read -p "Pilih opsi [1-6]: " choice
        case $choice in
            1) setup_server ;;
            2) add_website ;;
            3) list_websites ;;
            4) update_semua_situs ;;
            5) delete_website ;;
            6) log "info" "Terima kasih! 👋"; exit 0 ;;
            *) sleep 1 ;;
        esac
        read -n 1 -s -r -p "Tekan ENTER..."
    done
}

detect_os_php
main