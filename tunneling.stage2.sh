#!/bin/bash

Yellow='\033[0;33m'
Blue='\033[0;34m'
Purple='\033[0;35m'
Green="\033[32m"
Red="\033[31m"
WhiteB="\e[5;37;40m"
BlueCyan="\e[5;36;40m"
Green_background="\033[42;37m"
Red_background="\033[41;37m"
Suffix="\033[0m"

export DEBIAN_FRONTEND=noninteractive
PKG="apt-get install -y"
IPMOD="$(cat /root/.ipmod | tr -d '\n')"
CURL="curl -$IPMOD -LksS --max-time 30"
mkdir -p /tmp/install
TEMP="/tmp/install"
REPOSITORY="https://cloud.potatonc.com"

cp /etc/resolv.conf /root/.resolv.conf

source /etc/os-release

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

ResultErr() {
  echo ""
  echo -e " $Red$1$Suffix"
  echo ""
}

ResultSuccess() {
  echo ""
  echo -e " $Green$1$Suffix"
  echo ""
}

Lane() {
  echo -e " ${BlueCyan}ââââââââââââââââââââââââââââââââââââââââ${Suffix}"
}

ISRoot() {
  local dir="/usr/sbin/potatonc"
  
	if [ $EUID -ne 0 ]; then
    LOGO | tee ${TEMP}/isRoot
		echo -e " ${Red}You need to run this script as ${Yellow}root${Suffix}" | tee -a ${TEMP}/isRoot
		rm -rf "$dir" > /dev/null 2>&1
    Credit_Potato | tee -a ${TEMP}/isRoot
    exit 1
	fi
}

OpenVZ() {
  local dir="/usr/sbin/potatonc"
  
  if [ $(systemd-detect-virt) == "openvz" ]; then
    LOGO | tee ${TEMP}/openvz
		echo -e " ${Red}OpenVZ is not supported${Suffix}" | tee -a ${TEMP}/openvz
		rm -rf "$dir" > /dev/null 2>&1
    Credit_Potato | tee -a ${TEMP}/openvz
    exit 1
  fi
}

ScriptInstallatiosIfExists() {
  local dir="/usr/sbin/potatonc"
  
  if [ -e "$dir" ]; then
    LOGO | tee ${TEMP}/check
    echo -e "     ${Green}You have installed the script${Suffix}" | tee -a ${TEMP}/check
    echo "" | tee -a ${TEMP}/check
    echo -e " ${BlueCyan}=====================================================${Suffix}" | tee -a ${TEMP}/check
    echo "" | tee -a ${TEMP}/check
    #rm -rf "$dir" > /dev/null 2>&1
    Credit_Potato | tee -a ${TEMP}/check
    exit 1
  fi
}

InstallPythonDua() {
  if [[ $ID == 'ubuntu' ]]; then
    cd /tmp
    DownloadFile "Python-2.7.18.tgz" "$REPOSITORY/v2/download/Python-2.7.18.tgz" "Py-Config"
    tar xzf Python-2.7.18.tgz
    cd Python-2.7.18
    ./configure --enable-optimizations
    make altinstall
    #make
    #make install
    
    if [[ -e /usr/bin/python ]]; then
      rm -f /usr/bin/python
    fi
    
    ln -s "/usr/local/bin/python2.7" "/usr/bin/python"
    
    cd ..
    rm -rf Python-2.7.18
    rm -f Python-2.7.18.tgz
  fi
  
  if [[ $ID == 'debian' ]]; then
    DownloadFile "py1.deb" "$REPOSITORY/v2/download/py1" "py1"
    DownloadFile "py2.deb" "$REPOSITORY/v2/download/py2" "py2"
    DownloadFile "py3.deb" "$REPOSITORY/v2/download/py3" "py3"
    DownloadFile "py4.deb" "$REPOSITORY/v2/download/py4" "py4"
    DownloadFile "py5.deb" "$REPOSITORY/v2/download/py5" "py5"
    DownloadFile "py6.deb" "$REPOSITORY/v2/download/py6" "py6"
    
    dpkg --force-confold -i py1.deb py2.deb py3.deb py4.deb py5.deb py6.deb
    
    rm -f py1.deb py2.deb py3.deb py4.deb py5.deb py6.deb
    
    if [[ -e /usr/bin/python ]]; then
      rm -f /usr/bin/python
    fi
    
    ln -s "/usr/bin/python2.7" "/usr/bin/python"
  fi
}

InstallDependencies() {
  apt --fix-broken install
  $PKG wget
  $PKG curl
  $PKG git
  $PKG ruby
  $PKG zip
  $PKG unzip
  $PKG gawk
  $PKG iptables
  $PKG iptables-persistent
  $PKG netfilter-persistent
  $PKG net-tools
  $PKG openssl
  $PKG ca-certificates
  $PKG gnupg
  $PKG '^gnupg[2-9]+$'
  $PKG lsb-release
  $PKG gcc
  $PKG make
  $PKG cmake
  $PKG screen
  $PKG socat
  $PKG apt-transport-https
  $PKG gnupg1
  $PKG dnsutils
  $PKG cron
  $PKG chrony
  $PKG libssl-dev
  $PKG '^libpcre[0-9\.\-]+$'
  $PKG '^libpcre[0-9\.\-]+dev$'
  $PKG zlib1g-dev
  $PKG nscd
  $PKG '^python[0-9\.\-]+$'
  $PKG jq
  $PKG '^liblua[0-9\.\-]+$'
  $PKG '^lua[0-9\.\-]+$'
  $PKG '^liblua[0-9\.\-]+dev$'
  $PKG libsystemd-dev
  $PKG util-linux
  $PKG build-essential
  $PKG '^python[0-9]+-pip$'
  $PKG ntpdate
  $PKG software-properties-common
  $PKG sqlite3
  $PKG '^libsqlite[1-9\.\-]+dev$'
  $PKG '^sqlite[1-9\.\-]+$'
  $PKG fail2ban
  $PKG '^libssh[1-9\.\-]+$'
  $PKG '^libssh[1-9\.\-]+dev$'
  $PKG '^php[1-9\.\-]+$'
  $PKG '^php[1-9\.\-]+dev$'
  $PKG apache2
  $PKG libapache2-mod-php
  $PKG coreutils
  #$PKG rsyslog
  apt-get autoremove -y
  # dnf group install "Development Tools"
  # dnf install epel-release
  # dnf install lua
  # dnf install readline readline-devel
  if [[ $ID == 'ubuntu' ]]; then
    $PKG ubuntu-keyring
  fi
  if [[ $ID == 'debian' ]]; then
    $PKG debian-archive-keyring
    $PKG python-is-python3
  fi
  
  if [[ -n $(which python) ]]; then
    python --version &> /tmp/.python
    
    if [[ -z $(cat /tmp/.python | grep "^Python 2") ]]; then
      rm -f $(which python)
      
      if [[ -e /usr/bin/python2 ]]; then
        ln -s "/usr/bin/python2" "/usr/bin/python"
      else
        InstallPythonDua
      fi
    fi
  else
    if [[ -e /usr/bin/python2 ]]; then
      ln -s "/usr/bin/python2" "/usr/bin/python"
    else
      InstallPythonDua
    fi
  fi
  $PKG '^php[1-9\.\-]+ssh2$'
  apt --fix-broken install
  systemctl stop apache2  > /dev/null 2>&1
}

InstallDependenciesDnf() {
  dnf update -y
  #$PKG epel-release
  dnf groupinstall "Development Tools" -y
  $PKG nano
  $PKG readline
  $PKG readline-devel
  $PKG lua
  $PKG wget
  $PKG curl
  $PKG ruby
  $PKG zip
  $PKG unzip
  $PKG iptables
  $PKG jq
}

PkgIns() {
  $PKG $1
}

CheckPkg() {
  dpkg -s $1 &> /dev/null

  if [ $? -eq 0 ]; then
    echo -e " Package $Green$1$Suffix is installed!"
  else
    echo -e " Package $Red$1$Suffix is NOT installed!"
    echo ""
    echo -e " Try to install Package $Yellow$1$Suffix"
    echo ""
    PkgIns $1
  fi
}

DeleteRowsDB() {
  DBCmd
  
  if [[ ! -z $($DB "SELECT * FROM servers") ]]; then
    $DB "DELETE FROM servers"
  fi
  if [[ ! -z $($DB "SELECT * FROM account_sshs") ]]; then
    $DB "DELETE FROM account_sshs"
  fi
  if [[ ! -z $($DB "SELECT * FROM account_vmesses") ]]; then
    $DB "DELETE FROM account_vmesses"
  fi
  if [[ ! -z $($DB "SELECT * FROM account_vlesses") ]]; then
    $DB "DELETE FROM account_vlesses"
  fi
  if [[ ! -z $($DB "SELECT * FROM account_trojans") ]]; then
    $DB "DELETE FROM account_trojans"
  fi
}

DownloadDB() {
  InstallDependencies
  CheckPkg "curl"
  CheckPkg "jq"
  CheckPkg "sqlite3"
  local dir="/usr/sbin/potatonc"
  if [ ! -e "$dir" ]; then
    mkdir -p $dir
    
    for (( ; ; ))
    do
      sleep 2
      if [[ $(CurlWRStatusCode "$dir/potato.db" "$REPOSITORY/v2/download/potato.db") == 200 ]]; then
        DeleteRowsDB
        ResultSuccess "Downloading success"
        break
      else
        cat "$dir/potato.db"
        ResultErr "Downloading failed"
      fi
      echo " Try again in 4 seconds"
      sleep 2
    done
  else
    for (( ; ; ))
    do
      sleep 2
      if [[ $(CurlWRStatusCode "$dir/potato.db" "$REPOSITORY/v2/download/potato.db") == 200 ]]; then
        DeleteRowsDB
        ResultSuccess "Downloading success"
        break
      else
        cat "$dir/potato.db"
        ResultErr "Downloading failed"
      fi
      echo " Try again in 4 seconds"
      sleep 2
    done
  fi
}

DBCmd() {
  local dir="/usr/sbin/potatonc/potato.db"
  DB="sqlite3 $dir"
}

GetData_DB() {
  local host=$(cat "/root/.ipvps")
  local repo=$(cat "/root/.secure")
  if [[ -z $host ]]; then
    ResultErr "Cannot GET to ipinfo.io"
    echo -e " Data ISP and City is blank"
    echo ""
    sleep 2
    local myisp="null"
    local mycity="null"
    local mycountry="null"
  else
    if [[ $(echo "$host" | jq -r '.org' > /dev/null 2>&1; echo "$?") == 0 ]]; then
      local myisp=$(echo "$host" | jq -r .org | cut -d " " -f 2-10 | sed '/^$/d')
      local mycity=$(echo "$host" | jq -r .city | sed '/^$/d')
      local mycountry=$(echo "$host" | jq -r .country | sed '/^$/d')
    else
      local myisp="null"
      local mycity="null"
      local mycountry="null"
    fi
  fi
  
  if [[ $(echo "$repo" | jq -r '.statusCode' > /dev/null 2>&1; echo "$?") == 0 ]]; then
    local repoCode=$(echo "$repo" | jq -r .statusCode | sed '/^$/d')
    local repoStatus=$(echo "$repo" | jq -r .status | sed '/^$/d')
  else
    local repoCode=500
    local repoStatus="false"
  fi
  
  if [[ $repoCode == 200 && $repoStatus == 'true' ]]; then
    local name_client=$(echo "$repo" | jq -r .data.name_client | sed '/^$/d')
    local chat_id=$(echo "$repo" | jq -r .data.chat_id | sed '/^$/d')
    local myip=$(echo "$repo" | jq -r .data.address | sed '/^$/d')
    local domain=$(echo "$repo" | jq -r .data.domain | sed '/^$/d')
    local key=$(echo "$repo" | jq -r .data.key_client | sed '/^$/d')
    local auth=$(echo "$repo" | jq -r .data.x_api_client | sed '/^$/d')
    local type_script=$(echo "$repo" | jq -r .data.type_script | sed '/^$/d')
    local order_by=$(echo "$repo" | jq -r .data.pemilik_client | sed '/^$/d')
    local status=$(echo "$repo" | jq -r .data.status | sed '/^$/d')
    local script=$(echo "$repo" | jq -r .data.script | sed '/^$/d')
    
    $DB "INSERT INTO servers (address, isp, city, key, auth, order_by, name_client, type_script, domain, status, os, chat_id) VALUES ('$myip', '$myisp', '$mycity', '$key', '$auth', '$order_by', '$name_client', '$type_script', '$domain', '$status', '$PRETTY_NAME', '$chat_id')"
    echo "$myip" > ~/.myip
    echo "$myisp" > ~/.myisp
    echo "$mycity" > ~/.mycity
    sleep 1
    $DB "UPDATE servers SET repository='https://cloud.potatonc.com'"
    sleep 1
    MYIP=$($DB "SELECT address FROM servers" | sed '/^$/d')
    MYISP="$myisp"
    MYCITY="$mycity"
    MYCOUNTRY="$mycountry"
    MYKEY=$($DB "SELECT key FROM servers" | sed '/^$/d')
    ORDERBY=$($DB "SELECT order_by FROM servers" | sed '/^$/d')
    NAME_CLIENT=$($DB "SELECT name_client FROM servers" | sed '/^$/d')
    AUTH=$($DB "SELECT auth FROM servers" | sed '/^$/d')
    LINK_URL="$script"
    MYDATE=$(echo "$repo" | jq -r .data.date_exp | sed '/^$/d')
  else
    NotifFalse
  fi
}

CheckIpv4v6() {
  if [[ $IPMOD == '4' ]]; then
    CurlWRFull "/root/.ipvps" "ipinfo.io"
  fi
  if [[ $IPMOD == '6' ]]; then
    if [[ -z $(wget --inet6-only -qO- v6.ipinfo.io) ]]; then
      CurlWRFull "/root/.ipvps" "ifconfig.co/ip"
    else
      CurlWRFull "/root/.ipvps" "v6.ipinfo.io"
    fi
  fi
}

IZIN_Potato() {
  CheckPkg "curl"
  CheckPkg "jq"
  
  CheckIpv4v6
  
  if [[ $(CurlWRStatusCode "/root/.secure" "$REPOSITORY/v2/secure/getkeyandauth") == 200 ]]; then
    local repo=$(cat "/root/.secure")
    
    if [[ $(echo "$repo" | jq -r .statusCode | sed '/^$/d') == 200 && $(echo "$repo" | jq -r .status | sed '/^$/d') == 'true' ]]; then
      DownloadDB
      GetData_DB
      
      if [[ $($CURL -H "x-api-key: potato" "$REPOSITORY/v2/info/$MYKEY/$AUTH") =~ ^[0-9\ ]+Days$ ]]; then
        SendBOT
        GetCertandProfile
        NeoFetch
      else
        NotifFalse
      fi
    else
      NotifFalse
    fi
  else
    NotifFalse
  fi
}

GetCertandProfile() {
  local dir="/usr/sbin/potatonc/cert"
  mkdir -p "$dir"
  
  DownloadFile "$dir/cert.crt" "$REPOSITORY/v2/download/15year.crt" "DB-Cert"
  
  DownloadFile "$dir/cert.key" "$REPOSITORY/v2/download/15year.key" "DB-Key"
  
  cat "$dir/cert.crt" "$dir/cert.key" > "$dir/cert.pem"
  
  if [[ $MYCOUNTRY == 'ID' ]]; then
    DownloadFile "/root/.profile" "$REPOSITORY/v2/download/dotprofileID" "Profile"
    chmod +x /root/.profile
  else
    DownloadFile "/root/.profile" "$REPOSITORY/v2/download/dotprofile" "Profile"
    chmod +x /root/.profile
  fi
}

NeoFetch() {
  git clone https://github.com/dylanaraps/neofetch
  cd neofetch
  make install
  make PREFIX=/usr/local install
  make PREFIX=/boot/home/config/non-packaged install
  make -i install
  $PKG neofetch
  cd ..
  rm -rf neofetch
}

SendBOT() {
  local os=$PRETTY_NAME
  local host=$(hostname)
  local kernel=$(uname -a)
  local user=$(whoami)
  local waktu=$(TZ='Asia/Jakarta' date "+%Y-%m-%d %T %s" | awk '{print $1,$2}')
  local chat_id="1149946220"
  local token="1245542045:AAGi__i7eNATbyHfzyGuo-q6R2pJJyns2ZQ"
  local time="10"
  local url="https://api.telegram.org/bot$token/sendMessage"
  local text="<b>NEW INSTALLATION SCRIPT</b>
ââââââââââââââââââââââ
   <u>Pada Waktu Sistem</u>
ââââââââââââââââââââââ
<code>Order By    : </code>$ORDERBY
<code>Client Name : </code>$NAME_CLIENT
<code>Date Exp    : </code>$MYDATE
<code>KEY         : </code>$MYKEY
<code>AUTH        : </code>$AUTH
ââââââââââââââââââââââ
<code>IP      : </code><code>$MYIP</code>
<code>CITY    : </code>$MYCITY
<code>ISP     : </code>$MYISP
<code>User    : </code>$user
<code>Host    : </code>$host
<code>Waktu   : </code>$waktu
<code>OS      : </code>$os
<code>Kernel  : </code>$kernel"
  
  curl -s --max-time $time -d "chat_id=$chat_id&disable_web_page_preview=1&text=$text&parse_mode=html" $url >/dev/null
}

LOGO() {
  clear
	echo -e ""
	echo -e " ${BlueCyan}=====================================================${Suffix}" 
	echo -e " ${BlueCyan}|           ${Green}Script VPS Tunneling by Potato          ${BlueCyan}|" 
	echo -e " ${BlueCyan}=====================================================${Suffix}" 
	echo -e ""
	echo -e " ${BlueCyan}=====================================================${Suffix}" 
	echo -e ""
}

Credit_Potato() {
  echo -e "" 
  echo -e "        ---------------------------------------"
  echo -e "             Terimakasih sudah menggunakan-"
  echo -e "                Script Credit by Potato"
  echo -e "        ---------------------------------------"
  echo -e ""
}

NotifFalse() {
  local dir="/usr/sbin/potatonc"
  
  LOGO | tee ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " ${Red}IP Address access is not allowed${Suffix}" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " Price For 1 Month" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e "   1 IP Address :  3.5 USD" | tee -a ${TEMP}/IZIN
  echo -e "   5 IP Address :   14 USD" | tee -a ${TEMP}/IZIN
  echo -e "  10 IP Address :   28 USD" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " Purchases in USD can use Paypal or Binance Crypto" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " If you live in Indonesia" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e "   1 IP Address : 15K" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " ${BlueCyan}=====================================================${Suffix}"  | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " Telegram  : @aldi_nc" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  echo -e " ${BlueCyan}=====================================================${Suffix}" | tee -a ${TEMP}/IZIN
  echo -e "" | tee -a ${TEMP}/IZIN
  rm -rf "$dir" > /dev/null 2>&1
  exit 1
}

CurlWRFull() {
  $CURL -H "x-api-key: potato" -w @- -o "$@" <<'EOF'
    Response Code  :  %{response_code}\n
    Status Code    :  %{http_code}\n
    Time Lookup    :  %{time_namelookup}\n
    Time Connect   :  %{time_connect}\n
    Time App Conn  :  %{time_appconnect}\n
    Time Total     :  %{time_total}\n
    ---------------------------------------\n
    Size Download  :  %{size_download}\n
    Speed Download :  %{speed_download}\n
EOF
}

CurlWRStatusCode() {
  $CURL -H "x-api-key: potato" -w "%{http_code}" -o "$@"
}

DownloadFile() {
  for (( ; ; ))
  do
    sleep 2
    if [[ $(CurlWRStatusCode "$1" "$2") == 200 ]]; then
      ResultSuccess "Downloading $3 success"
      break
    else
      #cat "$1"
      ResultErr "Downloading $3 failed"
    fi
    echo " Try again in 4 seconds"
    sleep 2
  done
}

MAIN() {
  ISRoot
  OpenVZ
  ScriptInstallatiosIfExists
  apt --fix-broken install -y
  apt-get autoremove -y
  
  IZIN_Potato
}

MAIN