#!/bin/bash

C_RESET='\e[0m'
C_RED='\e[1;31m' C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m' C_BLUE='\e[1;34m'
C_MAGENTA='\e[1;35m' C_CYAN='\e[1;36m'
C_BOLD='\e[1m'

log() {
  local type=$1
  local msg=$2
  case "$type" in
    "info") echo -e "${C_BLUE}INFO:${C_RESET} $msg" ;;
    "success") echo -e "${C_GREEN}SUKSES:${C_RESET} $msg" ;;
    "warn") echo -e "${C_YELLOW}PERINGATAN:${C_RESET} $msg" ;;
    "error") echo -e "${C_RED}ERROR:${C_RESET} $msg${C_RESET}"; exit 1 ;;
  esac
}

run_task() {
  local description=$1
  shift
  local command_args=("$@")
  printf "${C_CYAN}  -> %s... ${C_RESET}" "$description"
  
  if sudo "${command_args[@]}" &> /dev/null; then
    echo -e "${C_GREEN}[OK]${C_RESET}"
    return 0
  else
    echo -e "${C_RED}[GAGAL]${C_RESET}"
    log "error" "Gagal menjalankan '$description'. Periksa log sistem untuk detail."
  fi
}

setup_server() {
  log "info" "Memulai instalasi dependensi dasar & optimasi..."
  
  run_task "Memperbarui daftar paket & menginstal prasyarat" apt-get update -y
  run_task "Menginstal software-properties-common dan nano" apt-get install -y software-properties-common nano

  log "info" "Menambahkan PPA untuk PHP 8.3..."
  run_task "Menambahkan PPA Ondrej/PHP" add-apt-repository -y ppa:ondrej/php
  run_task "Memperbarui daftar paket lagi" apt-get update -y

  log "info" "Menginstal paket-paket inti (Nginx, MariaDB, PHP 8.3, Fail2ban)..."
  run_task "Menginstal paket" apt-get install -y \
    nginx mariadb-server mariadb-client \
    unzip curl wget fail2ban \
    redis-server php8.3-fpm php8.3-mysql php8.3-xml \
    php8.3-curl php8.3-gd php8.3-imagick php8.3-mbstring \
    php8.3-zip php8.3-intl php8.3-bcmath php8.3-redis
  
  log "info" "Menginstal WP-CLI..."
  run_task "Mengunduh WP-CLI" wget -nv https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp
  run_task "Membuat WP-CLI executable" chmod +x /usr/local/bin/wp

  log "info" "Mengamankan instalasi MariaDB..."
  run_task "Mengaktifkan & memulai MariaDB" systemctl enable --now mariadb.service
  
  read -s -p "$(echo -e ${C_YELLOW}'Masukkan password untuk user root MariaDB: '${C_RESET})" mariadb_root_pass; echo
  if [ -z "$mariadb_root_pass" ]; then
    log "warn" "Password root kosong. MariaDB mungkin tidak sepenuhnya aman."
  else
    run_task "Mengatur password user root MariaDB" mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_root_pass';"
  fi
  run_task "Menghapus database tes dan user anonim" mysql -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.user WHERE User=''; FLUSH PRIVILEGES;"
  
  log "info" "Mengonfigurasi Nginx untuk FastCGI Caching..."
  local cache_conf="/etc/nginx/fastcgi-cache.conf"
  if [ ! -f "$cache_conf" ]; then
    sudo tee "$cache_conf" > /dev/null <<'EOF'
fastcgi_cache_path /var/run/nginx-cache levels=1:2 keys_zone=WORDPRESS:100m inactive=60m;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header http_500;
fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
EOF
    run_task "Menambahkan konfigurasi FastCGI ke nginx.conf" sed -i '\|http {|a include /etc/nginx/fastcgi-cache.conf;|' /etc/nginx/nginx.conf
  fi
  
  log "info" "Mengonfigurasi Firewall (UFW)..."
  run_task "Mengizinkan SSH" ufw allow 'OpenSSH'
  run_task "Mengizinkan Nginx (HTTP & HTTPS)" ufw allow 'Nginx Full'
  run_task "Mengaktifkan UFW" ufw --force enable

  log "info" "Mengonfigurasi Fail2Ban..."
  run_task "Membuat filter untuk login WordPress" sudo tee /etc/fail2ban/filter.d/wordpress-hard.conf > /dev/null <<EOF
[Definition]
failregex = ^<HOST> -.*"(GET|POST) /wp-login.php
ignoreregex =
EOF
  run_task "Menambahkan aturan WordPress ke jail.local" sudo tee -a /etc/fail2ban/jail.local > /dev/null <<EOF
[wordpress-hard]
enabled = true
port = http,https
filter = wordpress-hard
logpath = /var/log/nginx/access.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
  run_task "Mengaktifkan & memulai layanan Fail2Ban" systemctl enable --now fail2ban
  
  log "success" "Semua dependensi dasar & optimasi berhasil diinstal!"
}

add_website() {
  log "info" "Memulai proses instalasi website WordPress baru yang dioptimasi."
  
  while true; do
    read -p "$(echo -e ${C_YELLOW}'Masukkan nama domain (contoh: domain.com): '${C_RESET})" domain
    if [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      log "warn" "Format domain tidak valid. Mohon coba lagi."
    fi
  done
  
  local dbname=$(echo "$domain" | tr '.' '_' | cut -c1-16)_wp
  local dbuser=$(echo "$domain" | tr '.' '_' | cut -c1-16)_usr
  read -s -p "$(echo -e ${C_YELLOW}'Masukkan password untuk database user '${dbuser}': '${C_RESET})" dbpass; echo

  log "info" "Membuat database untuk '$domain'..."
  run_task "Membuat database '$dbname'" mysql -e "CREATE DATABASE $dbname;"
  run_task "Membuat user '$dbuser'" mysql -e "CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$dbpass';"
  run_task "Memberikan hak akses" mysql -e "GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost'; FLUSH PRIVILEGES;"
  
  local web_root="/var/www/$domain/public_html"
  log "info" "Mengunduh & mengonfigurasi WordPress..."
  run_task "Membuat direktori root" mkdir -p "$web_root"
  run_task "Mengubah kepemilikan direktori" chown -R www-data:www-data "/var/www/$domain"
  run_task "Mengunduh file WordPress" -u www-data wp core download --path="$web_root"
  
  run_task "Membuat file wp-config.php" -u www-data wp config create --path="$web_root" \
    --dbname="$dbname" --dbuser="$dbuser" --dbpass="$dbpass" \
    --extra-php <<'PHP'
define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
PHP

  local ssl_dir="/etc/nginx/ssl/$domain"
  run_task "Membuat direktori SSL" mkdir -p "$ssl_dir"
  local ssl_cert_path="$ssl_dir/$domain.crt"
  local ssl_key_path="$ssl_dir/$domain.key"
  
  echo -e "${C_YELLOW}Buka nano dan tempelkan konten sertifikat SSL (file .crt) di sini.${C_RESET}"
  read -p "$(echo -e ${C_BOLD}'Tekan ENTER untuk melanjutkan... '${C_RESET})"
  sudo nano "$ssl_cert_path"
  
  echo -e "${C_YELLOW}Buka nano dan tempelkan konten kunci privat SSL (file .key) di sini.${C_RESET}"
  read -p "$(echo -e ${C_BOLD}'Tekan ENTER untuk melanjutkan... '${C_RESET})"
  sudo nano "$ssl_key_path"

  log "info" "Membuat file konfigurasi Nginx..."
  sudo tee "/etc/nginx/sites-available/$domain" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain www.$domain;
    root $web_root;
    index index.php index.html index.htm;
    ssl_certificate $ssl_cert_path;
    ssl_certificate_key $ssl_key_path;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    client_max_body_size 100M;
    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap(_index)?.xml|/404.php") { set \$skip_cache 1; }
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set \$skip_cache 1; }
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 60m;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header X-Cache-Status \$upstream_cache_status;
    }
    location ~* /(?:wp-config.php|wp-content/debug.log|wp-content/themes/.*\.zip|uploads/.*\.php)$ {
        deny all;
        return 404;
    }
    location ~ /\.ht {
        deny all;
    }
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 5;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
        expires 365d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF
  run_task "Mengaktifkan site Nginx" ln -s /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/
  
  log "info" "Mengatur izin file dan menguji konfigurasi Nginx..."
  run_task "Mengatur izin direktori" find "$web_root" -type d -exec chmod 755 {} \;
  run_task "Mengatur izin file" find "$web_root" -type f -exec chmod 644 {} \;
  run_task "Membuat SSL DH params" openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
  run_task "Menguji konfigurasi Nginx" nginx -t
  run_task "Reload Nginx" systemctl reload nginx
  
  log "info" "Menyelesaikan instalasi WordPress & menginstal plugin cache..."
  read -p "$(echo -e ${C_YELLOW}'Judul Website: '${C_RESET})" site_title
  read -p "$(echo -e ${C_YELLOW}'Username Admin: '${C_RESET})" admin_user
  read -s -p "$(echo -e ${C_YELLOW}'Password Admin: '${C_RESET})" admin_password; echo
  read -p "$(echo -e ${C_YELLOW}'Email Admin: '${C_RESET})" admin_email
  
  run_task "Menginstal WordPress inti" -u www-data wp core install --path="$web_root" --url=https://"$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_password" --admin_email="$admin_email"
  run_task "Menginstal & mengaktifkan plugin Redis Cache" -u www-data wp plugin install redis-cache --activate --path="$web_root"
  run_task "Mengaktifkan Redis Object Cache" -u www-data wp redis enable --path="$web_root"
  
  log "success" "Instalasi WordPress super cepat untuk 'https://$domain' selesai! 🎉"
  log "warn" "Jangan lupa simpan info login admin dan database Anda."
}

list_websites() {
  log "info" "Mencari website yang dikelola oleh Nginx..."
  local sites_dir="/etc/nginx/sites-enabled"
  
  if [ -d "$sites_dir" ] && [ "$(ls -A $sites_dir)" ]; then
    echo -e "${C_BOLD}---------------------------------------------${C_RESET}"
    for site in $(ls -A $sites_dir); do
      if [ "$site" != "default" ]; then
        echo -e "  🌐 ${C_GREEN}$site${C_RESET} (https://$site)"
      fi
    done
    echo -e "${C_BOLD}---------------------------------------------${C_RESET}"
  else
    log "warn" "Tidak ada website yang ditemukan."
  fi
}

show_menu() {
  clear
  echo -e "${C_BOLD}${C_MAGENTA}"
  echo "=========================================================="
  echo "         🚀 SCRIPT INSTALASI WORDPRESS & OPTIMASI 🚀       "
  echo "=========================================================="
  echo -e "${C_RESET}"
  echo -e "  ${C_GREEN}1. Setup Server (Instalasi Dependensi & Optimasi) ⚙️${C_RESET}"
  echo -e "  ${C_BLUE}2. Tambah Website WordPress Baru (Cepat & Aman) ➕${C_RESET}"
  echo -e "  ${C_YELLOW}3. Lihat Daftar Website Terpasang 📜${C_RESET}"
  echo -e "  ${C_RED}4. Keluar ❌${C_RESET}"
  echo ""
}

main() {
  while true; do
    show_menu
    read -p "$(echo -e ${C_BOLD}'Pilih opsi [1-4]: '${C_RESET})" choice
    case $choice in
      1) setup_server ;;
      2) add_website ;;
      3) list_websites ;;
      4)
        log "info" "Terima kasih telah menggunakan skrip ini! 👋"
        exit 0
        ;;
      *)
        log "warn" "Pilihan tidak valid. Silakan coba lagi."
        sleep 2
        ;;
    esac
    echo
    read -n 1 -s -r -p "Tekan tombol apapun untuk kembali ke menu..."
  done
}

main