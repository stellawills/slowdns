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


source /etc/os-release
PKG="apt-get install -y"
IPMOD="$(cat /root/.ipmod | tr -d '\n')"
CURL="curl -$IPMOD -LksS --max-time 30"
apt --fix-broken install -y
apt update


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

DBCmd() {
  local dir="/usr/sbin/potatonc/potato.db"
  DB="sqlite3 $dir"
  REPOSITORY=$($DB "SELECT repository FROM servers" | sed '/^$/d')
}


InstallNginx() {
  DBCmd
  
  curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
  gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/$ID `lsb_release -cs` nginx" \
    | tee /etc/apt/sources.list.d/nginx.list
  echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | sudo tee /etc/apt/preferences.d/99nginx
  
  if [[ ${VERSION_ID} == '20.04' ]]; then
    dpkg --remove-architecture i386
  fi
  
  apt update
  $PKG nginx
  systemctl stop nginx > /dev/null 2>&1
  
  DownloadFile "/etc/nginx/conf.d/default.conf" "$REPOSITORY/v2/download/nginxdefault.conf" "Conf-Def"
  
  DownloadFile "/etc/nginx/nginx.conf" "$REPOSITORY/v2/download/nginx.conf" "Conf-Ng"
  
  DownloadFile "/etc/nginx/conf.d/publicagent.conf" "$REPOSITORY/v2/download/publicagent.conf" "Conf-Pub"
  
  if [[ ${ID} == 'ubuntu' || ${ID} == 'debian' ]]; then
    if [[ ${VERSION_ID} == '10' || ${VERSION_ID} == '20.04' ]]; then
      DownloadFile "/etc/nginx/conf.d/bdsm.conf" "$REPOSITORY/v2/download/bdsmold.conf" "Conf-Bd"
    else
      DownloadFile "/etc/nginx/conf.d/bdsm.conf" "$REPOSITORY/v2/download/bdsm.conf" "Conf-Bd"
    fi
  fi
  
  DownloadFile "/etc/nginx/conf.d/stepsister.conf" "$REPOSITORY/v2/download/stepsister.conf" "Conf-St"
  
  if [ -e /etc/nginx/mime.types.dpkg-dist ]; then
    cp /etc/nginx/mime.types.dpkg-dist /etc/nginx/mime.types
  fi
}

MAIN() {
  InstallNginx
}

MAIN