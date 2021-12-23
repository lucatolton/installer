#!/bin/bash

set -e

#############################################################################
#                                                                           #
# Jexactyl Installation Script                                              #
#                                                                           #
#   This program is free software: you can redistribute it and/or modify    #
#   it under the terms of the GNU General Public License as published by    #
#   the Free Software Foundation, either version 3 of the License, or       #
#   (at your option) any later version.                                     #
#                                                                           #
#   This program is distributed in the hope that it will be useful,         #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#   GNU General Public License for more details.                            #
#                                                                           #
#   You should have received a copy of the GNU General Public License       #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.  #
#                                                                           #
# https://github.com/Jexactyl - https://jexactyl.xyz                        #
#                                                                           #
#############################################################################

## General system checks
# Check if user is root
if [ "$(id -u)" != "0" ]; then
    echo "[!] This script must be ran as the root user."
    exit 1
fi

# Check if curl is installed
if ! [ -x "$(command -v curl)" ]; then
    echo "[!] Curl is not installed. Please install it and then continue with the installation."
    exit 1
fi


## Define variables
# Define the Github versions
GITHUB_SOURCE="master"

# Web configuration
FQDN=""

# MySQL configuration
MYSQL_DB="pterodactyl"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD=""

# Environment configuration
email=""

# Initial administrator account
user_email=""
user_username=""
user_firstname=""
user_lastname=""
user_password=""

# SSL configuration
ASSUME_SSL=false
CONFIGURE_LETSENCRYPT=false

# Download URLs
PANEL_DL_URL="https://github.com/Jexactyl/panel/releases/latest/download/panel.tar.gz"

# Firewall configuration
CONFIGURE_UFW=false
CONFIGURE_FIREWALL_CMD=false
CONFIGURE_FIREWALL=false

# Email input regex
regex="^(([A-Za-z0-9]+((\.|\-|\_|\+)?[A-Za-z0-9]?)*[A-Za-z0-9]+)|[A-Za-z0-9]+)@(([A-Za-z0-9]+)+((\.|\-|\_)?([A-Za-z0-9]+)+)*)+\.([A-Za-z]{2,})+$"


## Version checking
# Define version using Github information
get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
    grep '"tag_name":' |                                              # Get tag line
    sed -E 's/.*"([^"]+)".*/\1/'                                      # Pluck JSON value
}

# Panel version
echo "[*] Checking for the latest version of the panel..."
JEXACTYL_VERSION="$(get_latest_release "Jexactyl/panel")"


## Library functions
array_contains_element() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

valid_email() {
    [[ $1 =~ $regex ]]
}


## Visual functions
print_error() {
    COLOR_RED='\033[0;31m'
    COLOR_NC='\033[0m' # No Color

    echo ""
    echo -e "[${COLOR_RED}ERROR${COLOR_NC}] $1"
    echo ""
}

print_warning() {
    COLOR_YELLOW='\033[0;33m'
    COLOR_NC='\033[0m' # No Color

    echo ""
    echo -e "[${COLOR_YELLOW}WARNING${COLOR_NC}] $1"
    echo ""
}

print_break() {
    for ((n = 0; n < $1; n++)); do
        echo -n "="
    done
    echo ""
}

hyperlink() {
    echo -e "\e]8;;${1}\a${1}\e]8;;\a"
}


## User input functions
required_input() {
    local __resultvar=$1
    local result=''

    while [ -z "$result" ]; do
        echo -n "* ${2}"
        read -r result

        if [ -z "${3}" ]; then
            [ -z "$result" ] && result="${4}"
        else
            [ -z "$result" ] && print_error "${3}"
        fi
    done

    eval "$__resultvar="'$result'""
}

email_input() {
    local __resultvar=$1
    local result=''

    while ! valid_email "$result"; do
        echo -n "* ${2}"
        read -r result

        valid_email "$result" || print_error "${3}"
    done

    eval "$__resultvar="'$result'""
}

password_input() {
    local __resultvar=$1
    local result=''
    local default="$4"

    while [ -z "$result" ]; do
        echo -n "[*] ${2}"

        # modified from https://stackoverflow.com/a/22940001
        while IFS= read -r -s -n1 char; do
            [[ -z $char ]] && {
                printf '\n'
                break
            }                                                             # ENTER pressed; output \n and break.
            if [[ $char == $'\x7f' ]]; then # backspace was pressed
                # Only if variable is not empty
                if [ -n "$result" ]; then
                    # Remove last char from output variable.
                    [[ -n $result ]] && result=${result%?}
                    # Erase '*' to the left.
                    printf '\b \b'
                fi
            else
                # Add typed char to output variable.
                result+=$char
                # Print '*' in its stead.
                printf '*'
            fi
        done
        [ -z "$result" ] && [ -n "$default" ] && result="$default"
        [ -z "$result" ] && print_error "${3}"
    done

    eval "$__resultvar="'$result'""
}

ask_letsencrypt() {
    if [ "$CONFIGURE_UFW" == false ] && [ "$CONFIGURE_FIREWALL_CMD" == false ]; then
        print_warning "Let's Encrypt requires port 80/443 to be opened! You have opted out of the automatic firewall configuration; use this at your own risk (if port 80/443 is closed, the script will fail)!"
    fi

    print_warning "You cannot use Let's Encrypt with your hostname as an IP address! It must be a FQDN (e.g. panel.example.org)."

    echo -e -n "[*] Do you want to automatically configure HTTPS using Let's Encrypt? (y/N): "
    read -r CONFIRM_SSL

    if [[ "$CONFIRM_SSL" =~ [Yy] ]]; then
        CONFIGURE_LETSENCRYPT=true
        ASSUME_SSL=false
    fi
}

ask_assume_ssl() {
    echo "[*] Let's Encrypt is not going to be automatically configured by this script (user opted out)."
    echo "[*] You can 'assume' Let's Encrypt, which means the script will download a nginx configuration that is configured to use a Let's Encrypt certificate but the script won't obtain the certificate for you."
    echo "[*] If you assume SSL and do not obtain the certificate, your installation will not work."
    echo -n "[*] Assume SSL or not? (y/N): "
    read -r ASSUME_SSL_INPUT

    [[ "$ASSUME_SSL_INPUT" =~ [Yy] ]] && ASSUME_SSL=true
    true
}

ask_firewall() {
    case "$OS" in
    ubuntu | debian)
        echo -e -n "[*] Do you want to automatically configure UFW (firewall)? (y/N): "
        read -r CONFIRM_UFW

        if [[ "$CONFIRM_UFW" =~ [Yy] ]]; then
            CONFIGURE_UFW=true
            CONFIGURE_FIREWALL=true
        fi
        ;;
    centos)
        echo -e -n "[*] Do you want to automatically configure firewall-cmd (firewall)? (y/N): "
        read -r CONFIRM_FIREWALL_CMD

        if [[ "$CONFIRM_FIREWALL_CMD" =~ [Yy] ]]; then
            CONFIGURE_FIREWALL_CMD=true
            CONFIGURE_FIREWALL=true
        fi
        ;;
    esac
}


## OS checking functions
detect_distro() {
    if [ -f /etc/os-release ]; then
        # freedesktop.org and systemd
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        # linuxbase.org
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        # For some versions of Debian/Ubuntu without lsb_release command
        . /etc/lsb-release
        OS=$DISTRIB_ID
        VER=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS=Debian
        VER=$(cat /etc/debian_version)
    elif [ -f /etc/SuSe-release ]; then
        # Older SuSE/etc.
        OS=SuSE
        VER=$(cat /etc/SuSe-release)
    elif [ -f /etc/redhat-release ]; then
        # Older Red Hat, CentOS, etc.
        OS=RedHat
        VER=$(cat /etc/redhat-release)
    else
        # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
        OS=$(uname -s)
        VER=$(uname -r)
    fi
}

check_os_comp() {
    CPU_ARCHITECTURE=$(uname -m)
    if [ "$CPU_ARCHITECTURE" == "x86_64" ]; then
        print_warning "Detected CPU architecture $CPU_ARCHITECTURE"
        print_warning "Using any other architecture than x86_64 may cause issues."

        echo -e -n "[*] Do you want to continue? (y/N): "
        read -r choice

        if [[ ! "$choice" =~ [Yy] ]]; then
            print_error "Installation aborted"
            exit 1
        fi
    fi

    case "$OS" in
    ubuntu)
        PHP_SOCKET="/run/php/php8.0-fpm.sock"
        [ "$OS_VER_MAJOR" == "18" ] && SUPPORTED=true
        [ "$OS_VER_MAJOR" == "20" ] && SUPPORTED=true
        ;;
    debian)
        PHP_SOCKET="/run/php/php7.2-fpm.sock"
        [ "$OS_VER_MAJOR" == "9" ] && SUPPORTED=true
        [ "$OS_VER_MAJOR" == "10" ] && SUPPORTED=true
        [ "$OS_VER_MAJOR" == "11" ] && SUPPORTED=true
        ;;
    centos)
        PHP_SOCKET="/var/run/php-fpm/pterodactyl.sock"
        [ "$OS_VER_MAJOR" == "7" ] && SUPPORTED=true
        [ "$OS_VER_MAJOR" == "8" ] && SUPPORTED=true
        ;;
    *)
        SUPPORTED=false
        ;;
    esac

    if [ "$SUPPORTED" == true ]; then
        echo "[*] $OS $OS_VER is supported, continuing installation"
    else
        print_error "$OS $OS_VER is not supported, aborting installation"
        exit 1
    fi
}


## Main installation functions
# Install composer
install_composer() {
    echo "[*] Installing Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    echo "[*] Done!"
}

# Download panel files
ptdl_dl() {
    echo "[*] Downloading Jexactyl files, please wait..."
    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl || exit

    curl -Lo panel.tar.gz "$PANEL_DL_URL"
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/

    cp .env.example .env
    [ "$OS" == "centos" ] && export PATH=/usr/local/bin:$PATH
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

    php artisan key:generate --force
    echo "[*] Done!"
}

# Create database
create_database() {
    if [ "$OS" == "centos" ]; then
        # secure mariaDB
        echo "[*] MariaDB secure installation. The following are safe defaults."
        echo "[*] Set root password? [Y/n] Y"
        echo "[*] Remove anonymous users? [Y/n] Y"
        echo "[*] Disallow root login remotely? [Y/n] Y"
        echo "[*] Remove test database and access to it? [Y/n] Y"
        echo "[*] Reload privilege tables now? [Y/n] Y"
        echo "[*] --------------------------------------------------"

        [ "$OS_VER_MAJOR" == "7" ] && mariadb-secure-installation
        [ "$OS_VER_MAJOR" == "8" ] && mysql_secure_installation

        echo "[*] The script should have asked you to set the MySQL root password earlier (not to be confused with the Pterodactyl database user password)"
        echo "[*] Please type the password before each command."

        echo "[*] Create MySQL user"
        mysql -u root -p -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

        echo "[*] Create MySQL database"
        mysql -u root -p -e "CREATE DATABASE ${MYSQL_DB};"

        echo "[*] Grant privileges to user"
        mysql -u root -p -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}' WITH GRANT OPTION;"

        echo "[*] Flush privileges"
        mysql -u root -p -e "FLUSH PRIVILEGES;"

    else
        echo "[*] Performing MySQL queries"

        echo "[*] Create MySQL user"
        mysql -u root -p -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

        echo "[*] Create MySQL database"
        mysql -u root -p -e "CREATE DATABASE ${MYSQL_DB};"

        echo "[*] Grant privileges to user"
        mysql -u root -p -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}' WITH GRANT OPTION;"

        echo "[*] Flush privileges"
        mysql -u root -p -e "FLUSH PRIVILEGES;"
    fi
}

# Configure environment
configure() {
    app_url="http://$FQDN"
    [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
    [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

    echo "[*] Configuring environment..."
    php artisan p:environment:setup \
        --author="$email" \
        --url="$app_url" \
        --timezone="$timezone" \
        --cache="redis" \
        --session="redis" \
        --queue="redis" \
        --redis-host="localhost" \
        --redis-pass="null" \
        --redis-port="6379" \
        --settings-ui=true
    
    php artisan p:environment:database \
        --host="127.0.0.1" \
        --port="3306" \
        --database="$MYSQL_DB" \
        --username="$MYSQL_USER" \
        --password="$MYSQL_PASSWORD"
    
    php artisan migrate --seed --force

    php artisan p:user:make \
        --email="$user_email" \
        --username="$iser_username" \
        --name-first="$user_firstname" \
        --name-last="$user_lastname" \
        --password="$password" \
        --admin=1
}

# Set folder permissions
set_folder_permissions() {
    echo "[*] Setting folder permissions"
    case "$OS" in
    debian | ubuntu)
        chown -R www-data:www-data ./*
        ;;
    centos)
        chown -R nginx:nginx ./*
        ;;
    esac
}

# Insert cronjob
insert_cronjob() {
    echo "[*] Installing cronjob"

    crontab -l | {
        cat
        echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
    } | crontab -
}

# Install pteroq service
install_pteroq() {
    echo "[*] Installing pteroq service"
    
    curl -o /etc/systemd/system/pteroq.service https://raw.githubusercontent.com/Jexactyl/panel/$GITHUB_SOURCE/configs/pteroq.service

    case "$OS" in
    debian | ubuntu)
        sed -i -e "s@<user>@www-data@g" /etc/systemd/system/pteroq.service
        ;;
    centos)
        sed -i -e "s@<user>@nginx@g" /etc/systemd/system/pteroq.service
        ;;
    esac

    systemctl enable pteroq.service
    systemctl start pteroq
}

## OS specific functions
apt_update() {
    apt update -q -y && apt upgrade -y
}

yum_update() {
    yum -y update
}

dnf_update() {
    dnf -y upgrade
}

enable_services_debian_based() {
    systemctl enable mariadb
    systemctl enable redis-server
    systemctl start mariadb
    systemctl start redis-server
}

enable_services_centos_based() {
    systemctl enable mariadb
    systemctl enable nginx
    systemctl enable redis
    systemctl start mariadb
    systemctl start redis
}

selinux_allow() {
    setsebool -P httpd_can_network_connect 1 || true
    setsebool -P http_execmem 1 || true
    setsebool -P httpd_unified 1 || true
}

ubuntu20_dep() {
    echo "[*] Installing dependencies for Ubuntu 20.04"

    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

    add-apt-repository universe

    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

    apt_update

    apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server redis cron

    enable_services_debian_based

    echo "[*] Dependencies installed"
}

ubuntu18_dep() {
    echo "[*] Installing dependencies for Ubuntu 18.04"

    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

    add-apt-repository universe

    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

    apt_update

    apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server redis cron

    enable_services_debian_based

    echo "[*] Dependencies installed"
}

debian_stretch_dep() {
    echo "[*] Installing dependencies for Debian 8/9"

    apt -y install dirmngr

    apt install ca-certificates apt-transport-https lsb-release -y
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list

    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

    apt_update

    apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip git redis-server cron

    enable_services_debian_based

    echo "[*] Dependencies installed"
}

debian_buster_dep() {
    echo "[*] Installing dependencies for Debian 10"

    apt -y install dirmngr

    apt install ca-certificates apt-transport-https lsb-release -y
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list

    apt_update

    apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip git redis-server cron

    enable_services_debian_based

    echo "[*] Dependencies installed"
}

debian_dep() {
    echo "[*] Installing dependencies for Debian 11"

    apt -y install dirmngr

    apt install ca-certificates apt-transport-https lsb-release -y
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list

    apt_update

    apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip git redis-server cron

    enable_services_debian_based

    echo "[*] Dependencies installed"
}

centos7_dep() {
    echo "[*] Installing dependencies for CentOS 7"

    # SELinux tools
    yum install -y policycoreutils policycoreutils-python selinux-policy selinux-policy-targeted libselinux-utils setroubleshoot-server setools setools-console mcstrans

    # Add remi repo (php8.0)
    yum install -y epel-release http://rpms.remirepo.net/enterprise/remi-release-7.rpm
    yum install -y yum-utils
    yum-config-manager -y --disable remi-php54
    yum-config-manager -y --enable remi-php80
    yum_update

    # Install MariaDB
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

    # Install dependencies
    yum -y install php php-common php-tokenizer php-curl php-fpm php-cli php-json php-mysqlnd php-mcrypt php-gd php-mbstring php-pdo php-zip php-bcmath php-dom php-opcache mariadb-server nginx curl tar zip unzip git redis

    # Enable services
    enable_services_centos_based

    # SELinux (allow nginx and redis)
    selinux_allow

    echo "[*] Dependencies installed"
}

centos8_dep() {
    echo "[*] Installing dependencies for CentOS 8"

    # SELinux tools
    dnf install -y policycoreutils selinux-policy selinux-policy-targeted setroubleshoot-server setools setools-console mcstrans

    # add remi repo (php8.0)
    dnf install -y epel-release http://rpms.remirepo.net/enterprise/remi-release-8.rpm
    dnf module enable -y php:remi-8.0
    dnf_update

    dnf install -y php php-common php-fpm php-cli php-json php-mysqlnd php-gd php-mbstring php-pdo php-zip php-bcmath php-dom php-opcache

    # MariaDB (use from official repo)
    dnf install -y mariadb mariadb-server

    # Other dependencies
    dnf install -y nginx curl tar zip unzip git redis

    # Enable services
    enable_services_centos_based

    # SELinux (allow nginx and redis)
    selinux_allow

    echo "[*] Dependencies installed!"
}

## Other OS specific functions
centos_php() {
    curl -o /etc/php-fpm.d/www-pterodactyl.conf $GITHUB_BASE_URL/configs/www-pterodactyl.conf

    systemctl enable php-fpm
    systemctl start php-fpm
}

firewall_ufw() {
    apt install -y ufw

    echo -e "\n[*] Enabling Uncomplicated Firewall (UFW)"
    echo "[*] Opening port 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

    # pointing to /dev/null silences the command output
    ufw allow ssh >/dev/null
    ufw allow http >/dev/null
    ufw allow https >/dev/null

    ufw --force enable
    ufw --force reload
    ufw status numbered | sed '/v6/d'
}

firewall_firewalld() {
    echo -e "\n[*] Enabling firewall_cmd (firewalld)"
    echo "[*] Opening port 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

    # Install
    [ "$OS_VER_MAJOR" == "7" ] && yum -y -q install firewalld >/dev/null
    [ "$OS_VER_MAJOR" == "8" ] && dnf -y -q install firewalld >/dev/null

    # Enable
    systemctl --now enable firewalld >/dev/null # Enable and start

    # Configure
    firewall-cmd --add-service=http --permanent -q    # Port 80
    firewall-cmd --add-service=https --permanent -q   # Port 443
    firewall-cmd --add-service=ssh --permanent -q     # Port 22
    firewall-cmd --reload -q                          # Enable firewall

    echo "[*] Firewall-cmd installed"
    print_break 70
}

letsencrypt() {
    FAILED=false

    # Install certbot
    case "$OS" in
    debian | ubuntu)
        apt-get -y install certbot python3-certbot-nginx
        ;;
    centos)
        [ "$OS_VER_MAJOR" == "7" ] && yum -y -q install certbot python-certbot-nginx
        [ "$OS_VER_MAJOR" == "8" ] && dnf -y -q install certbot python3-certbot-nginx
        ;;
    esac

    # Obtain certificate
    certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

    # Check if it succeded
    if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
        print_warning "The process of obtaining a Let's Encrypt certificate failed!"
        echo -n "[*] Still assume SSL? (y/N): "
        read -r CONFIGURE_SSL

        if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
            ASSUME_SSL=true
            CONFIGURE_LETSENCRYPT=false
            configure_nginx
        else
            ASSUME_SSL=false
            CONFIGURE_LETSENCRYPT=false
        fi
    fi
}

## Main functions
perform_install() {
    echo "[*] Starting installation.. this might take a while!"

    case "$OS" in
    debian | ubuntu)
        apt_update

        [ "$CONFIGURE_UFW" == true ] && firewall_ufw

        if [ "$OS" == "ubuntu" ]; then
            [ "$OS_VER_MAJOR" == "20" ] && ubuntu20_dep
            [ "$OS_VER_MAJOR" == "18" ] && ubuntu18_dep
        elif [ "$OS" == "debian" ]; then
            [ "$OS_VER_MAJOR" == "9" ] && debian_stretch_dep
            [ "$OS_VER_MAJOR" == "10" ] && debian_buster_dep
            [ "$OS_VER_MAJOR" == "11" ] && debian_dep
        fi
        ;;

    centos)
        [ "$OS_VER_MAJOR" == "7" ] && yum_update
        [ "$OS_VER_MAJOR" == "8" ] && dnf_update

        [ "$CONFIGURE_FIREWALL_CMD" == true ] && firewall_firewalld

        [ "$OS_VER_MAJOR" == "7" ] && centos7_dep
        [ "$OS_VER_MAJOR" == "8" ] && centos8_dep
        ;;
    esac

    [ "$OS" == "centos" ] && centos_php
    install_composer
    ptdl_dl
    create_database
    configure
    set_folder_permissions
    insert_cronjob
    install_pteroq
    configure_nginx
    [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt
    true
}

main() {
    # check if we can detect an already existing installation
    if [ -d "/var/www/pterodactyl" ]; then
        print_warning "The script has detected that you already have an instance of Pterodactyl panel installed. You cannot run this script twice as it will fail."
        echo -e -n "[*] Are you sure you want to proceed? (y/N): "
        read -r CONFIRM_PROCEED
        if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
            print_error "Installation aborted!"
            exit 1
        fi
    fi

    # detect distro
    detect_distro

    print_break 70
    echo "[*] Jexactyl Installation Script"
    echo "[*]"
    echo "[*] This program is redistributed under the GNU General Public License."
    echo "[*] You can edit, copy or redistribute it under the terms of said license."
    echo "[*]"
    echo "[*] Latest panel release is $JEXACTYL_VERSION"
    print_break 70

    # checks if the system is compatible with this installation script
    check_os_comp

    # set database credentials
    print_break 72
    echo "[*] Database configuration."
    echo ""
    echo "[*] This will be the credentials used for communication between the MySQL"
    echo "[*] database and the panel. You do not need to create the database"
    echo "[*] before running this script, the script will do that for you."
    echo ""

    MYSQL_DB="-"
    while [[ "$MYSQL_DB" == *"-"* ]]; do
        required_input MYSQL_DB "Database name (panel): " "" "panel"
        [[ "$MYSQL_DB" == *"-"* ]] && print_error "Database name cannot contain hyphens"
    done

    MYSQL_USER="-"
    while [[ "$MYSQL_USER" == *"-"* ]]; do
        required_input MYSQL_USER "Database username (pterodactyl): " "" "pterodactyl"
        [[ "$MYSQL_USER" == *"-"* ]] && print_error "Database user cannot contain hyphens"
    done

    # MySQL password input
    rand_pw=$(
        tr -dc 'A-Za-z0-9!"#$%&()*+,-./:;<=>?@[\]^_`{|}~' </dev/urandom | head -c 64
        echo
    )
    password_input MYSQL_PASSWORD "Password (press enter to use randomly generated password): " "MySQL password cannot be empty" "$rand_pw"

    readarray -t valid_timezones <<<"$(curl -s $GITHUB_BASE_URL/configs/valid_timezones.txt)"
    echo "[*] List of valid timezones here $(hyperlink "https://www.php.net/manual/en/timezones.php")"

    while [ -z "$timezone" ]; do
        echo -n "[*] Select timezone [Europe/London]: "
        read -r timezone_input

        array_contains_element "$timezone_input" "${valid_timezones[@]}" && timezone="$timezone_input"
        [ -z "$timezone_input" ] && timezone="Europe/London" # uk all the way 
    done

    email_input email "Provide the email address that will be used to configure Let's Encrypt and Pterodactyl: " "Email cannot be empty or invalid"

    # Initial admin account
    email_input user_email "Email address for the initial admin account: " "Email cannot be empty or invalid"
    required_input user_username "Username for the initial admin account: " "Username cannot be empty"
    required_input user_firstname "First name for the initial admin account: " "Name cannot be empty"
    required_input user_lastname "Last name for the initial admin account: " "Name cannot be empty"
    password_input user_password "Password for the initial admin account: " "Password cannot be empty"

    print_break 72

    # set FQDN
    while [ -z "$FQDN" ]; do
        echo -n "[*] Set the FQDN of this panel (panel.example.com): "
        read -r FQDN
        [ -z "$FQDN" ] && print_error "FQDN cannot be empty"
    done

    # Ask if firewall is needed
    ask_firewall

    # Ask if letsencrypt is needed
    ask_letsencrypt

    # If it's already true, this should be a no-brainer
    [ "$CONFIGURE_LETSENCRYPT" == false ] && ask_assume_ssl

    # verify FQDN if user has selected to assume SSL or configure Let's Encrypt
    [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ] && bash <(curl -s $GITHUB_BASE_URL/lib/verify-fqdn.sh) "$FQDN" "$OS"

    # summary
    summary

    # confirm installation
    echo -e -n "\n[*] Initial configuration completed. Continue with installation? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ [Yy] ]]; then
        perform_install
    else
        # run welcome script again
        print_error "Installation aborted."
        exit 1
    fi
}

summary() {
    print_break 62
    echo "[*] Pterodactyl panel $JEXACTYL_VERSION with nginx on $OS"
    echo "[*] Database name: $MYSQL_DB"
    echo "[*] Database user: $MYSQL_USER"
    echo "[*] Database password: (censored)"
    echo "[*] Timezone: $timezone"
    echo "[*] Email: $email"
    echo "[*] User email: $user_email"
    echo "[*] Username: $user_username"
    echo "[*] First name: $user_firstname"
    echo "[*] Last name: $user_lastname"
    echo "[*] User password: (censored)"
    echo "[*] Hostname/FQDN: $FQDN"
    echo "[*] Configure Firewall? $CONFIGURE_FIREWALL"
    echo "[*] Configure Let's Encrypt? $CONFIGURE_LETSENCRYPT"
    echo "[*] Assume SSL? $ASSUME_SSL"
    print_break 62
}

goodbye() {
    print_break 62
    echo "[*] Panel installation completed"
    echo "[*]"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && echo "[*] Your panel should be accessible from $(hyperlink "$app_url")"
    [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && echo "[*] You have opted in to use SSL, but not via Let's Encrypt automatically. Your panel will not work until SSL has been configured."
    [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && echo "[*] Your panel should be accessible from $(hyperlink "$app_url")"

    echo "[*]"
    echo "[*] Installation is using nginx on $OS"
    echo "[*] Thank you for using this script."
    [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Note${COLOR_NC}: If you haven't configured the firewall: 80/443 (HTTP/HTTPS) is required to be open!"
    print_break 62
}

# run script
main
goodbye
