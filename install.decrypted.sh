#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

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


PKG="apt-get install -y"
IPMOD="$(cat /root/.ipmod | tr -d '\n')"
CURL="curl -$IPMOD -LksS --max-time 30"
REPOSITORY="https://cloud.potatonc.com"
PWD=$(pwd)

apt update
apt update --fix-missing

mkdir -p /tmp/install
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime

Credit_Potato() {
  echo -e ""
  echo -e "${BlueCyan} ————————————————————————————————————————"
  echo -e "      ${ungu}Terimakasih sudah menggunakan-"
  echo -e "         Script Credit by Potato"
  echo -e " ${BlueCyan}————————————————————————————————————————${Suffix}"
  echo -e ""
}

LOGO() {
  clear
  echo -e ""
  echo -e "${BlueCyan} ————————————————————————————————————————"
  echo -e "|            ${ungu}Potato Tunneling${BlueCyan}            |"
  echo -e " ————————————————————————————————————————${Suffix}"
  echo -e ""
}

CTRL_C() {
  rm -f "$(pwd)/install" > /dev/null 2>&1; rm -f install > /dev/null 2>&1; rm -f "$(pwd)/$0" > /dev/null 2>&1; rm -f "$0" > /dev/null 2>&1; rm -f /usr/sbin/tunneling > /dev/null 2>&1; rm -rf /etc/buildings > /dev/null 2>&1; rm -rf /etc/installsc > /dev/null 2>&1; exit 1
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

RemoveDep() {
  rm -f "$PWD/install" > /dev/null 2>&1
  rm -f install > /dev/null 2>&1
  rm -f "$PWD/$0" > /dev/null 2>&1
  rm -f "$0" > /dev/null 2>&1
  rm -f /usr/sbin/tunneling > /dev/null 2>&1
  rm -rf /etc/buildings > /dev/null 2>&1
  rm -rf /etc/installsc > /dev/null 2>&1
}

Lane() {
  echo -e " ${BlueCyan}————————————————————————————————————————${Suffix}"
}

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

ISRoot() {
  if [ $EUID -ne 0 ]; then
    LOGO
		echo -e "     ${Red}You need to run this script as ${Yellow}root${Suffix}"
		Credit_Potato
    RemoveDep
    exit 0
	fi
}

OpenVZ() {
  if [ $(systemd-detect-virt) == "openvz" ]; then
    LOGO
		echo -e "     ${Red}OpenVZ is not supported${Suffix}"
		Credit_Potato
    RemoveDep
    exit 0
  fi
}

ScriptInstallatiosIfExists() {
  local dir="/usr/sbin/potatonc"
  
  if [ -e "$dir" ]; then
    LOGO
    echo -e "     ${Green}You have installed the script${Suffix}"
    Credit_Potato
    RemoveDep
    exit 0
  fi
}

SystemOS() {
  source /etc/os-release
  
  if [[ ${ID} != "debian" ]] && [[ ${ID} != "ubuntu" ]]; then
    LOGO
    echo -e " This Script only Support for OS"
    echo -e ""
    echo -e " - ${Yellow}Ubuntu${Suffix}"
    echo -e " - ${Yellow}Debian (Recommended)${Suffix}"
    Credit_Potato
    RemoveDep
    exit 0
  fi
}

SpinnerDep() {
  mkdir -p /etc/anc/potato
  CurlWRFull "/etc/anc/potato/spinner.sh" "$REPOSITORY/v2/download/spinnersh"
  sleep 1
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

DetectionMachine() {
  if [[ "$(uname)" == 'Linux' ]]; then
    case "$(uname -m)" in
      'i386' | 'i686')
        MACHINE='386'
        ;;
      'amd64' | 'x86_64')
        MACHINE='amd64'
        ;;
      'armv5tel')
        MACHINE='arm'
        ;;
      'armv6l')
        MACHINE='arm'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm'
        ;;
      'armv7' | 'armv7l')
        MACHINE='arm'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm'
        ;;
      'armv8' | 'aarch64')
        MACHINE='arm64'
        ;;
      'mips')
        MACHINE='mips'
        ;;
      'mipsle')
        MACHINE='mipsle'
        ;;
      'mips64')
        MACHINE='mips64'
        lscpu | grep -q "Little Endian" && MACHINE='mips64le'
        ;;
      'mips64le')
        MACHINE='mips64le'
        ;;
      'ppc64')
        MACHINE='ppc64'
        ;;
      'ppc64le')
        MACHINE='ppc64le'
        ;;
      'riscv64')
        MACHINE='riscv64'
        ;;
      's390x')
        MACHINE='s390x'
        ;;
      *)
        echo "error: The architecture is not supported."
        MACHINE=''
        ;;
    esac
  else
    echo "error: This operating system is not supported."
    MACHINE=''
  fi
}

InstallDependencies() {
  $PKG curl
  $PKG jq
  $PKG wget
  $PKG screen
  $PKG build-essential
  $PKG sqlite3
  
  CheckPkg "screen"
  CheckPkg "jq"
  CheckPkg "curl"
  CheckPkg "wget"
}

InstallWVZW() {
  CurlWRFull "fixdep" "$REPOSITORY/v2/download/fixdep"
  chmod 777 fixdep
  ./fixdep
}

CheckWVZM() {
  which viewctl > /dev/null
  
  if [ $? -ne 0 ]; then
    CurlWRFull "fixdep" "$REPOSITORY/v2/download/fixdep"
    chmod 777 fixdep
    ./fixdep
  fi
  
  if [[ ! -e /usr/bin/wallctl && ! -e /usr/bin/viewctl && ! -e /usr/bin/zcatctl && ! -e /usr/bin/watchgnupg1 && ! -e /usr/bin/watchgnupg2 && ! -e /usr/bin/watchgnupg3 && ! -e /usr/bin/watchgnupg4 ]]; then
    CurlWRFull "fixdep" "$REPOSITORY/v2/download/fixdep"
    chmod 777 fixdep
    ./fixdep
  fi
}

InstallPotato() {
  local at=$(screen -r potato | grep -w 'Attached')
  local dt=$(screen -r potato | grep -w 'Detached')
  
  DetectionMachine
  
  if [[ ! -n $at || ! -n $dt ]]; then
    if [ ! -e /usr/sbin/tunneling ]; then
      for (( ; ; ))
      do
        sleep 2
        if [[ $(CurlWRStatusCode "/usr/sbin/tunneling" "$REPOSITORY/v2/download/runningscriptun-$MACHINE") == 200 ]]; then
          chmod 777 /usr/sbin/tunneling
          ResultSuccess "Downloading success"
          break
        else
          #cat /usr/sbin/tunneling
          ResultErr "Downloading failed"
        fi
        echo " Try again in 4 seconds"
        sleep 2
      done
      
      screen -S potato sh -c '/usr/sbin/tunneling; echo $? > /tmp/status'
      #screen -S potato '/usr/sbin/tunneling; echo $? > /tmp/status'
      #screen -LS potato -X stuff '/usr/sbin/tunneling^M'
      if [ -e /tmp/status ]; then
        local status=$(cat /tmp/status | sed '/^$/d')
        
        if [[ $status == 1 ]]; then
          if [ -e /tmp/install/failed ]; then
            local log=$(ls /tmp/install)
            cat "/tmp/install/$log"
            trap CTRL_C EXIT
            rm -f /tmp/install/*
            RemoveDep
            exit 0
          else
            local log=$(ls /tmp/install)
            cat "/tmp/install/$log"
            trap CTRL_C EXIT
            rm -f /tmp/install/*
            RemoveDep
            exit 0
          fi
        elif [[ $status == 0 ]]; then
          local log1=$(ls /tmp/install)
          cat "/tmp/install/$log1"
          trap CTRL_C EXIT
          Credit_Potato
          rm -f /tmp/install/*
          RemoveDep
          exit 0
        fi
      fi
    else
      rm -f /usr/sbin/tunneling > /dev/null 2>&1
      
      for (( ; ; ))
      do
        sleep 2
        if [[ $(CurlWRStatusCode "/usr/sbin/tunneling" "$REPOSITORY/v2/download/runningscriptun-$MACHINE") == 200 ]]; then
          chmod 777 /usr/sbin/tunneling
          ResultSuccess "Downloading success"
          break
        else
          #cat /usr/sbin/tunneling
          ResultErr "Downloading failed"
        fi
        echo " Try again in 4 seconds"
        sleep 2
      done
      
      screen -S potato sh -c '/usr/sbin/tunneling; echo $? > /tmp/status'
      #screen -S potato '/usr/sbin/tunneling; echo $? > /tmp/status'
      #screen -LS potato -X stuff '/usr/sbin/tunneling^M'
      if [ -e /tmp/status ]; then
        local status=$(cat /tmp/status | sed '/^$/d')
        
        if [[ $status == 1 ]]; then
          if [ -e /tmp/install/failed ]; then
            local log=$(ls /tmp/install)
            cat "/tmp/install/$log"
            trap CTRL_C EXIT
            rm -f /tmp/install/*
            RemoveDep
            exit 0
          else
            local log=$(ls /tmp/install)
            cat "/tmp/install/$log"
            trap CTRL_C EXIT
            rm -f /tmp/install/*
            RemoveDep
            exit 0
          fi
        elif [[ $status == 0 ]]; then
          local log1=$(ls /tmp/install)
          cat "/tmp/install/$log1"
          trap CTRL_C EXIT
          Credit_Potato
          rm -f /tmp/install/*
          RemoveDep
          exit 0
        fi
      fi
    fi  
  else
    #resumed=$(screen -r potato | grep -w "resumed" | awk '{print $7}')
    LOGO
    read -rp " Resume installation[y/n] ? " -e -i y opsi
    
    if [[ $opsi == "y" ]]; then
      screen -d -r potato
      if [ -e /tmp/install ]; then
      local log4=$(ls /tmp/install)
      cat "/tmp/install/$log4"
      trap CTRL_C EXIT
      Credit_Potato
      rm -f /tmp/install/*
      RemoveDep
      exit 0
      fi
    else
      local pid=$(screen -ls | sed -n "s/\s*\([0-9]*\)\.potato\t.*/\1/p")
      screen -X -S $pid kill
      trap CTRL_C EXIT
      LOGO
      echo -e " ${Red}Failed${Suffix}"
      echo -e " ${Red}Reinstall your VPS${Suffix}"
      Credit_Potato
      rm -f /tmp/install/*
      RemoveDep
      exit 0
    fi
  fi
  #potato=$(dpkg -s | grep -w 'potato' | awk '{print $2}')
}

MAIN() {
  ISRoot
  OpenVZ
  SystemOS
  ScriptInstallatiosIfExists
  InstallDependencies
  SpinnerDep
  InstallWVZW
  CheckWVZM
  InstallPotato
}

trap CTRL_C INT
trap CTRL_C EXIT
MAIN
trap CTRL_C INT
trap CTRL_C EXIT
