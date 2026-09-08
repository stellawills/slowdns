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
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
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


mkdir -p /usr/sbin/potatonc/style
mkdir -p /usr/sbin/potatonc/sshdb
mkdir -p /etc/potatonc/limit/sshdb
mkdir -p /usr/sbin/potatonc/udp
echo "10m" > /usr/sbin/potatonc/mebot
echo "10m" > /usr/sbin/potatonc/bckbot

#echo "* * * * * root /usr/sbin/cpryw" > /etc/cron.d/slebew

SystemdFunc() {
cat > /etc/systemd/system/rc-local.service <<-END
[Unit]
Description=rc-local
ConditionPathExists=/etc/rc.local
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99
[Install]
WantedBy=multi-user.target
END

cat > /etc/rc.local <<-END
#!/bin/sh -e
# rc.local
# By default this script does nothing.
#/etc/sysctl.d
#/etc/init.d/procps restart
exit 0
END

cat > /etc/systemd/system/tunws.service <<-END
[Unit]
Description=WebSocket By ePro
After=syslog.target network-online.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=/usr/sbin/ws-epro -f /usr/sbin/tunws.conf
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
END

cat > /etc/systemd/system/tunws@.service <<-END
[Unit]
Description=Websocket Python
Documentation=https://stackoverflow.com
After=network.target nss-lookup.target

[Service]
User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
Restart=on-failure
ExecStart=/usr/bin/python -O /usr/sbin/%i.py

[Install]
WantedBy=multi-user.target
END

cat > /etc/systemd/system/ikus@.service <<-END
[Unit]
Description=Potato Backend
Documentation=https://stackoverflow.com
After=network.target nss-lookup.target

[Service]
User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
Restart=on-failure
ExecStart=/usr/sbin/%i.pota

[Install]
WantedBy=multi-user.target
END

cat > /etc/systemd/system/cuagfs.service <<-END
[Unit]
Description=Potato Backend
Documentation=https://stackoverflow.com
After=network.target nss-lookup.target

[Service]
#User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
#Restart=on-failure
ExecStart=/usr/sbin/cuagfs

[Install]
WantedBy=multi-user.target
END

cat > /etc/systemd/system/dns-server.service <<-END
[Unit]
Description=Potato Backend
Documentation=https://stackoverflow.com
After=network.target nss-lookup.target

[Service]
User=root
EnvironmentFile=/usr/sbin/envslowdns
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
Restart=on-failure
ExecStart=/usr/sbin/dns-server -udp \$LISTEN_SERVER -privkey-file \$CONFIG_PRIV \$NAMESERVER \$SERVICE_SERVER

[Install]
WantedBy=multi-user.target
END

cat > /etc/systemd/system/dns-client.service <<-END
[Unit]
Description=Potato Backend
Documentation=https://stackoverflow.com
After=network.target nss-lookup.target

[Service]
User=root
EnvironmentFile=/usr/sbin/envslowdns
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
Restart=on-failure
ExecStart=/usr/sbin/dns-client -udp \$LISTEN_CLIENT -pubkey-file \$CONFIG_PUB \$NAMESERVER \$SERVICE_CLIENT

[Install]
WantedBy=multi-user.target
END
}

StartService() {
  chmod +x /etc/rc.local
  chmod 777 /etc/rc.local
  systemctl enable rc-local > /dev/null 2>&1
  systemctl start rc-local > /dev/null 2>&1
  
  sed -i 's/listen 80 default_server/listen 81 default_server/g' /etc/nginx/conf.d/default.conf
  
  systemctl enable local > /dev/null 2>&1
  systemctl start local > /dev/null 2>&1
  
  systemctl daemon-reload
  systemctl disable vnstat > /dev/null 2>&1
  systemctl enable vnstat > /dev/null 2>&1
  systemctl start vnstat > /dev/null 2>&1
  update-rc.d vnstat defaults
  service vnstat start
  vnstat --add -i ${NIC}
  systemctl restart vnstat > /dev/null 2>&1
  service vnstat restart
  systemctl restart cron > /dev/null 2>&1
}

AddVnstat() {
  cd /tmp
  DownloadFile "vnstat.tar.gz" "$REPOSITORY/v2/download/vnstat.tar.gz" "Vnstat"
  
  tar zxvf vnstat.tar.gz
  cd vnstat-2.10
  chmod +x configure
  ./configure --prefix=/usr --sysconfdir=/etc --disable-dependency-tracking && make && make install
  cp -v examples/systemd/simple/vnstat.service /etc/systemd/system/
  cp -v examples/init.d/debian/vnstat /etc/init.d/
  cd ..
  sed -i 's/Interface "eth0"/Interface "'""$NIC""'"/g' /etc/vnstat.conf;
  sed -i 's/;Interface "eth0"/Interface "'""$NIC""'"/g' /etc/vnstat.conf;
  rm -rf vnstat-2.10
  rm -f vnstat.tar.gz
}

AddStyleJson() {
  mkdir -p /root/stylee
  cd /root/stylee
  
  DownloadFile "stylejson.zip" "$REPOSITORY/v2/download/stylejson.zip" "Style-Json"
  unzip -qq -o stylejson.zip
  rm -f stylejson.zip
  chmod 777 *
  mv * /usr/sbin/potatonc/style/
  cd /root
  rm -rf stylee
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

InstallationApiGolang() {
  local name="potatonewapi"
  
  DetectionMachine
  sleep 1
  DownloadFile "/usr/bin/aus-cloud" "$REPOSITORY/v2/download/$name-$MACHINE" "Restful-API"
  chmod 777 /usr/bin/aus-cloud
  
  cat > /etc/systemd/system/aus-cloud.service <<-END
[Unit]
Description=Potato API
Documentation=https://stackoverflow.com
After=network.target nss-lookup.target

[Service]
User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
ExecStartPre=/usr/sbin/rmsckifex
ExecStart=/usr/bin/aus-cloud
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
END
}

MAIN() {
  DBCmd
  
  systemctl daemon-reload
  
  SystemdFunc
  AddVnstat
  #AddStyleJson
  StartService
  
  InstallationApiGolang
  systemctl daemon-reload
  systemctl enable aus-cloud > /dev/null 2>&1
  systemctl start aus-cloud > /dev/null 2>&1
}

MAIN
