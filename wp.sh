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
    printf "${C_CYAN}    -> %s... ${C_RESET}" "$description"
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

setup_fail2ban() {
    log "header" "KONFIGURASI FAIL2BAN"
    
    tee /etc/fail2ban/filter.d/wordpress.conf > /dev/null <<EOF
[Definition]
failregex = ^<HOST>.* "POST /wp-login.php
            ^<HOST>.* "POST /xmlrpc.php
ignoreregex =
EOF

    tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true

[wordpress]
enabled = true
port = http,https
filter = wordpress
logpath = /var/log/nginx/*/access.log
maxretry = 3
EOF

    mkdir -p /var/log/nginx/default
    touch /var/log/nginx/default/access.log
    
    run_task "Memulai ulang Fail2Ban" systemctl restart fail2ban
    run_task "Mengaktifkan Fail2Ban saat boot" systemctl enable fail2ban
}

setup_server() {
    log "header" "MEMULAI SETUP SERVER"
    log "info" "Menggunakan OS terdeteksi: $PRETTY_NAME"
    if [[ "$PHP_VERSION" == "Tidak Didukung" ]]; then
        log "error" "Versi Ubuntu '$OS_CODENAME' tidak didukung secara otomatis oleh skrip ini."
    fi
    log "success" "Versi PHP yang akan digunakan untuk $OS_CODENAME: PHP $PHP_VERSION"

    run_task "Memperbarui daftar paket" apt-get update -y --allow-releaseinfo-change || log "error" "Gagal memperbarui paket."

    if ! dpkg -s software-properties-common &> /dev/null; then
        run_task "Menginstal software-properties-common" apt-get install -y software-properties-common || log "error"
    fi

    if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        run_task "Menambahkan PPA ondrej/php" add-apt-repository -y ppa:ondrej/php || log "error"
        run_task "Memperbarui daftar paket lagi" apt-get update -y --allow-releaseinfo-change || log "error"
    fi

    local core_packages=(nginx mariadb-server mariadb-client unzip curl wget fail2ban ufw)
    local php_packages=(
        "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" 
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-zip" 
        "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath"
    )
    local packages_needed=("${core_packages[@]}" "${php_packages[@]}")
    local packages_to_install=()
    for pkg in "${packages_needed[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            packages_to_install+=("$pkg")
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        run_task "Menginstal paket yang dibutuhkan" apt-get install -y "${packages_to_install[@]}" || log "error"
    fi

    if ! command -v wp &> /dev/null; then
        run_task "Menginstal WP-CLI" wget -qO /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x /usr/local/bin/wp || log "error"
    fi

    run_task "Memulai layanan MariaDB" systemctl enable --now mariadb.service || log "error"
    load_or_create_password
    mysql -u root -p"$mariadb_unified_pass" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass';" 2>/dev/null || mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_unified_pass';"

    if ! ufw status | grep -q "Status: active"; then
        run_task "Konfigurasi Firewall" ufw allow 'OpenSSH' && ufw allow 'Nginx Full' && ufw --force enable || log "error"
    fi
    
    setup_fail2ban
    
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
        log "error" "Versi Ubuntu '$OS_CODENAME' tidak didukung."
    fi

    log "header" "TAMBAH WEBSITE WORDPRESS BARU"
    load_or_create_password
    local domain web_root dbname dbuser
    prompt_input "Nama domain (contoh: domainanda.com)" domain
    web_root="/var/www/$domain/public_html"
    dbname=$(generate_db_credentials "$domain" "_wp")
    dbuser=$(generate_db_credentials "$domain" "_usr")

    if [ -f "/etc/nginx/sites-enabled/$domain" ]; then
        log "error" "Konflik: Konfigurasi untuk $domain sudah ada."
    fi

    run_task "Membuat database dan user" mysql -u root -p"$mariadb_unified_pass" -e "CREATE DATABASE $dbname; CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$mariadb_unified_pass'; GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;" || log "error"
    run_task "Membuat direktori root" mkdir -p "$web_root" && chown -R www-data:www-data "/var/www/$domain" || log "error"
    run_task "Mengunduh WordPress" sudo -u www-data wp core download --path="$web_root" || log "error"
    run_task "Membuat wp-config" sudo -u www-data wp config create --path="$web_root" --dbname="$dbname" --dbuser="$dbuser" --dbpass="$mariadb_unified_pass" || log "error"

    log "header" "KONFIGURASI SSL"
    local ssl_dir="/etc/nginx/ssl/$domain"
    mkdir -p "$ssl_dir"
    local ssl_cert_path="$ssl_dir/$domain.crt"
    local ssl_key_path="$ssl_dir/$domain.key"
    echo -e "${C_YELLOW}Tempelkan isi sertifikat (.crt), lalu Ctrl+X, Y, Enter${C_RESET}"
    read -p "ENTER..." && nano "$ssl_cert_path"
    echo -e "${C_YELLOW}Tempelkan isi Kunci Privat (.key), lalu Ctrl+X, Y, Enter${C_RESET}"
    read -p "ENTER..." && nano "$ssl_key_path"

    local log_dir="/var/log/nginx/$domain"
    mkdir -p "$log_dir"

    tee "/etc/nginx/sites-enabled/$domain" > /dev/null <<EOF
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $domain www.$domain;
    root $web_root;
    index index.php;
    access_log $log_dir/access.log;
    error_log $log_dir/error.log;
    ssl_certificate $ssl_cert_path;
    ssl_certificate_key $ssl_key_path;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location = /xmlrpc.php { deny all; }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }
}
EOF

    nginx -t && systemctl reload nginx
    
    log "header" "INSTALASI WORDPRESS"
    local site_title admin_user admin_password admin_email
    prompt_input "Judul Website" site_title
    prompt_input "Username Admin" admin_user
    prompt_input "Password Admin" admin_password -s
    prompt_input "Email Admin" admin_email
    
    sudo -u www-data wp core install --path="$web_root" --url="https://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email"
    sudo -u www-data wp plugin install wp-file-manager disable-comments-rb floating-ads-bottom post-views-counter seo-by-rank-math --activate --path="$web_root"
    
    systemctl reload fail2ban
    log "success" "Instalasi $domain selesai!"
}

list_websites() {
    log "header" "DAFTAR WEBSITE"
    local sites_dir="/etc/nginx/sites-enabled"
    ls -A "$sites_dir" | grep -v "default"
}

update_semua_situs() {
    log "header" "PEMBARUAN SEMUA SITUS"
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
    prompt_input "Nama domain" domain
    rm "/etc/nginx/sites-enabled/$domain"
    rm -rf "/var/www/$domain"
    rm -rf "/etc/nginx/ssl/$domain"
    rm -rf "/var/log/nginx/$domain"
    systemctl reload nginx
    log "success" "Website $domain dihapus."
}

show_menu() {
    clear
    echo "=========================================================="
    echo "          🚀 SCRIPT MANAJEMEN WORDPRESS 🚀                "
    echo "=========================================================="
    echo " 1. Setup Awal Server & Fail2Ban"
    echo " 2. Tambah Website WordPress"
    echo " 3. Lihat Daftar Website"
    echo " 4. Perbarui Semua Situs"
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
        read -n 1 -s -r -p "Tekan tombol apapun..."
    done
}

detect_os_php
main