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


DAT_PATH="/usr/local/share/xray"
JSON_PATH="/etc/default/syncron"
CON_PATH="/etc/xray"
BIN_PATH="/usr/bin"
LOG_PATH="/var/log/xray"
SYS_PATH="/etc/systemd/system"

PathShare() {
  mkdir -p "$DAT_PATH"
  mkdir -p "$JSON_PATH/paradis"
  mkdir -p "$JSON_PATH/sketsa"
  mkdir -p "$JSON_PATH/drawit"
  mkdir -p "$CON_PATH"
  mkdir -p "$LOG_PATH"
  chmod 644 "$JSON_PATH/paradis"
  chmod 644 "$JSON_PATH/sketsa"
  chmod 644 "$JSON_PATH/drawit"
}

DownloadFileXrayLoop() {
  DBCmd
  
  NAME_CLIENT=$($DB "SELECT name_client FROM servers" | sed '/^$/d')
  NAME_CLIENT="${NAME_CLIENT//[^[:alnum:]]}"
  NAME_CLIENT="${NAME_CLIENT,,}$(</dev/urandom tr -dc a-z | head -c15)"
  DOMAIN=$($DB "SELECT domain FROM servers" | sed '/^$/d')
  
  local url="https://github.com/XTLS/Xray-core/releases/download/v1.8.11"
  local download_link_geoip="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
  local download_link_geosite="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
  
  DetectionMachine
  
  if [[ $MACHINE != '' ]]; then
    PathShare
    
    DownloadFile "/tmp/Xray-linux-$MACHINE.zip" "$REPOSITORY/v2/download/Xray-linux-$MACHINE.zip" "Xray-linux-$MACHINE"
    
    cd /tmp
    unzip -qq -o "/tmp/Xray-linux-$MACHINE.zip"
    mv "/tmp/xray" "$BIN_PATH/xray"
    chmod +x "$BIN_PATH/xray"
    rm -f "/tmp/Xray-linux-$MACHINE.zip"
    
    sleep 1
    DownloadFile "$BIN_PATH/geoip.dat" "$REPOSITORY/v2/download/geoip.dat" "Geoip"
    sleep 1
    DownloadFile "$BIN_PATH/geosite.dat" "$REPOSITORY/v2/download/geosite.dat" "Geosite"
    sleep 1
    DownloadFile "$BIN_PATH/iplst.dat" "$REPOSITORY/v2/download/iplst.dat" "GeoLst"
    
    chmod 644 "$BIN_PATH/geoip.dat"
    chmod 644 "$BIN_PATH/geosite.dat"
    chmod 644 "$BIN_PATH/iplst.dat"
    
    if [[ -z $(which xray) ]]; then
      DownloadFile "/tmp/Xray-linux-$MACHINE.zip" "$REPOSITORY/v2/download/Xray-linux-$MACHINE.zip" "Xray-linux-$MACHINE"
      
      cd /tmp
      unzip -qq -o "/tmp/Xray-linux-$MACHINE.zip"
      mv "/tmp/xray" "$BIN_PATH/xray"
      chmod +x "$BIN_PATH/xray"
      rm -f "/tmp/Xray-linux-$MACHINE.zip"
    fi
    
    cd
    
    JsonParadis
    JsonInboundsVmess
    JsonOutboundsVmess
    JsonRulesVmess
    
    JsonSketsa
    JsonInboundsVless
    JsonOutboundsVless
    JsonRulesVless
    
    JsonDrawit
    JsonInboundsTrojan
    JsonOutboundsTrojan
    JsonRulesTrojan
    
    SystemdXray
    
    systemctl daemon-reload
    systemctl enable paradis > /dev/null 2>&1
    systemctl enable sketsa > /dev/null 2>&1
    systemctl enable drawit > /dev/null 2>&1
    systemctl start paradis > /dev/null 2>&1
    systemctl start sketsa > /dev/null 2>&1
    systemctl start drawit > /dev/null 2>&1
    systemctl restart paradis > /dev/null 2>&1
    systemctl restart sketsa > /dev/null 2>&1
    systemctl restart drawit > /dev/null 2>&1
    
    FirewallACCEPT
  fi
}

DetectionMachine() {
  if [[ "$(uname)" == 'Linux' ]]; then
    case "$(uname -m)" in
      'i386' | 'i686')
        MACHINE='32'
        ;;
      'amd64' | 'x86_64')
        MACHINE='64'
        ;;
      'armv5tel')
        MACHINE='arm32-v5'
        ;;
      'armv6l')
        MACHINE='arm32-v6'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
      'armv7' | 'armv7l')
        MACHINE='arm32-v7a'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
      'armv8' | 'aarch64')
        MACHINE='arm64-v8a'
        ;;
      'mips')
        MACHINE='mips32'
        ;;
      'mipsle')
        MACHINE='mips32le'
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

SystemdXray() {
  if [[ $MACHINE != '' ]]; then
cat > "$SYS_PATH/paradis.service" <<-END
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
ExecStart=/usr/bin/xray run -config /etc/default/syncron/paradis/vmess.json
ExecStartPost=/usr/bin/xray api adi --server=127.0.0.1:10001 /etc/default/syncron/paradis/paradis.json
ExecStartPost=/usr/bin/xray api ado --server=127.0.0.1:10001 /etc/default/syncron/paradis/outbounds.json
ExecStartPost=/usr/bin/xray api adrules --server=127.0.0.1:10001 /etc/default/syncron/paradis/rules.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
END

cat > "$SYS_PATH/sketsa.service" <<-END
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
ExecStart=/usr/bin/xray run -config /etc/default/syncron/sketsa/vless.json
ExecStartPost=/usr/bin/xray api adi --server=127.0.0.1:10002 /etc/default/syncron/sketsa/sketsa.json
ExecStartPost=/usr/bin/xray api ado --server=127.0.0.1:10002 /etc/default/syncron/sketsa/outbounds.json
ExecStartPost=/usr/bin/xray api adrules --server=127.0.0.1:10002 /etc/default/syncron/sketsa/rules.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
END

cat > "$SYS_PATH/drawit.service" <<-END
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#NoNewPrivileges=true
ExecStart=/usr/bin/xray run -config /etc/default/syncron/drawit/trojan.json
ExecStartPost=/usr/bin/xray api adi --server=127.0.0.1:10003 /etc/default/syncron/drawit/drawit.json
ExecStartPost=/usr/bin/xray api ado --server=127.0.0.1:10003 /etc/default/syncron/drawit/outbounds.json
ExecStartPost=/usr/bin/xray api adrules --server=127.0.0.1:10003 /etc/default/syncron/drawit/rules.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
END
  fi
}


JsonOutboundsVless() {
  cat> "$JSON_PATH/sketsa/outbounds.json" <<-END
{
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
END
  cp "$JSON_PATH/sketsa/outbounds.json" "$JSON_PATH/sketsa/outbounds.json.bak"
}

JsonRulesVless() {
  cat> "$JSON_PATH/sketsa/rules.json" <<-END
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END
  cp "$JSON_PATH/sketsa/rules.json" "$JSON_PATH/sketsa/rules.json.bak"
}

JsonInboundsVless() {
  local uuid=$(cat /proc/sys/kernel/random/uuid)
  cat> "$JSON_PATH/sketsa/sketsa.json" <<-END
{
  "inbounds": [
    {
      "port": 58,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/worryfree"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "ws"
    },
    {
      "port": 1057,
      "listen":"127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "grpc"
    },
    {
      "port": 57,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "acceptProxyProtocol": true,
          "path": "/upvless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "httpupgrade"
    },
    {
      "port": 1058,
      "listen":"127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "tcp"
    }
  ]
}
END
  cp "$JSON_PATH/sketsa/sketsa.json" "$JSON_PATH/sketsa/sketsa.json.bak"

  cat> /usr/sbin/potatonc/.routingvless << END
PROTOCOL="VLESS"
HOST="${DOMAIN}"
UUID="${uuid}"
PATH="/vless"
END
}

JsonSketsa() {
  cat> "$JSON_PATH/sketsa/vless.json" << END
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "HandlerService",
      "RoutingService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "log": {
    "access": "/var/log/xray/access2.log",
    "error": "/var/log/xray/error2.log",
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "dokodemo-door",
        "settings": {
          "address": "127.0.0.1"
        },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END
  cp "$JSON_PATH/sketsa/vless.json" "$JSON_PATH/sketsa/vless.json.bak"
}


JsonOutboundsTrojan() {
  cat> "$JSON_PATH/drawit/outbounds.json" <<-END
{
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
END
  cp "$JSON_PATH/drawit/outbounds.json" "$JSON_PATH/drawit/outbounds.json.bak"
}

JsonRulesTrojan() {
  cat> "$JSON_PATH/drawit/rules.json" <<-END
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END
  cp "$JSON_PATH/drawit/rules.json" "$JSON_PATH/drawit/rules.json.bak"
}

JsonInboundsTrojan() {
  local uuid=$(cat /proc/sys/kernel/random/uuid)
  cat> "$JSON_PATH/drawit/drawit.json" <<-END
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 1059,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password":"${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "tcp"
    },
    {
      "listen": "127.0.0.1",
      "port": 1060,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password":"${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/trojan"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "ws"
    },
    {
      "listen": "127.0.0.1",
      "port": 1062,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password":"${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "acceptProxyProtocol": true,
          "path": "/uptrojan"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "httpupgrade"
    },
    {
      "listen": "127.0.0.1",
      "port": 1061,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password":"${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "trojan"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "grpc"
    }
  ]
}
END
  cp "$JSON_PATH/drawit/drawit.json" "$JSON_PATH/drawit/drawit.json.bak"

  cat> /usr/sbin/potatonc/.routingtrojan << END
PROTOCOL="TROJAN"
HOST="${DOMAIN}"
UUID="${uuid}"
PATH="/trojan"
END
}

JsonDrawit() {
  cat> "$JSON_PATH/drawit/trojan.json" << END
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "HandlerService",
      "RoutingService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "log": {
    "access": "/var/log/xray/access3.log",
    "error": "/var/log/xray/error3.log",
    "loglevel": "info"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10003,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END
  cp "$JSON_PATH/drawit/trojan.json" "$JSON_PATH/drawit/trojan.json.bak"
}


JsonOutboundsVmess() {
  cat> "$JSON_PATH/paradis/outbounds.json" <<-END
{
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
END
  cp "$JSON_PATH/paradis/outbounds.json" "$JSON_PATH/paradis/outbounds.json.bak"
}

JsonRulesVmess() {
  cat> "$JSON_PATH/paradis/rules.json" <<-END
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END
  cp "$JSON_PATH/paradis/rules.json" "$JSON_PATH/paradis/rules.json.bak"
}

JsonInboundsVmess() {
  local uuid=$(cat /proc/sys/kernel/random/uuid)
  cat> "$JSON_PATH/paradis/paradis.json" <<-END
{
  "inbounds": [
    {
      "port": 55,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/worryfree"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "ws"
    },
    {
      "port": 1054,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vmess"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "grpc"
    },
    {
      "port": 54,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "acceptProxyProtocol": true,
          "path": "/upvmess"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "httpupgrade"
    },
    {
      "port": 1055,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
          "network": "tcp",
          "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "tcp"
    }
  ]
}
END
  cp "$JSON_PATH/paradis/paradis.json" "$JSON_PATH/paradis/paradis.json.bak"

  cat> /usr/sbin/potatonc/.routingvmess << END
PROTOCOL="VMESS"
HOST="${DOMAIN}"
UUID="${uuid}"
PATH="/vmess"
END
}

JsonParadis() {
  cat> "$JSON_PATH/paradis/vmess.json" << END
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "HandlerService",
      "RoutingService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "dokodemo-door",
        "settings": {
          "address": "127.0.0.1"
        },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END
  cp "$JSON_PATH/paradis/vmess.json" "$JSON_PATH/paradis/vmess.json.bak"
}


JsonSketsaTMP() {
  local uuid=$(cat /proc/sys/kernel/random/uuid)
cat> "$JSON_PATH/sketsa/sketsa.json" << END
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "HandlerService",
      "RoutingService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "log": {
    "access": "/var/log/xray/access2.log",
    "error": "/var/log/xray/error2.log",
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "port": 56,
      "listen":"0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/worryfree"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "port": 1056,
      "listen":"127.0.0.1",
      "protocol": "vless",
        "settings": {
          "clients": [
            {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
            }
          ],
          "decryption": "none"
        },
        "streamSettings": {
          "network": "grpc",
          "grpcSettings": {
            "serviceName": "vless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "port": 1058,
      "listen":"127.0.0.1",
      "protocol": "vless",
        "settings": {
          "clients": [
            {
            "id": "${uuid}",
            "email": "${NAME_CLIENT}"
            }
          ],
          "decryption": "none"
        },
        "streamSettings": {
          "network": "tcp",
          "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "dokodemo-door",
        "settings": {
          "address": "127.0.0.1"
        },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    },
    {
      "mux": {
        "concurrency": 8,
        "enabled": false
      },
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "user2.networkstoreid.asia",
            "port": 80,
            "users": [
              {
                "alterId": 0,
                "encryption": "",
                "flow": "",
                "id": "dc64073d-f617-4b4d-a175-b46f759d91a0",
                "level": 8,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "headers": {
            "Host": "user2.networkstoreid.asia"
          },
          "path": "/vmess"
        }
      },
      "tag": "Indonesia"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "netflix.com",
          "vidio.com",
          "dana.id",
          "geosite:google",
          "geosite:netflix"
        ],
        "network": "tcp,udp",
        "outboundTag": "Indonesia"
      },
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END

cat> /root/.routingvless << END
PROTOCOL="VLESS"
HOST="${DOMAIN}"
UUID="${uuid}"
PATH="/vless"
END
}

JsonDrawitTMP() {
  local uuid=$(cat /proc/sys/kernel/random/uuid)
cat> "$JSON_PATH/drawit/drawit.json" << END
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "HandlerService",
      "RoutingService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "log": {
    "access": "/var/log/xray/access3.log",
    "error": "/var/log/xray/error3.log",
    "loglevel": "info"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 1059,
      "protocol": "trojan",
      "settings": {
      "clients": [
        {
          "password":"${uuid}",
          "email": "${NAME_CLIENT}"
        }
      ]
    },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 57,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password":"${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/trojan"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 1057,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password":"${uuid}",
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
            "serviceName": "trojan"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10003,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    },
    {
      "mux": {
        "concurrency": 8,
        "enabled": false
      },
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "user2.networkstoreid.asia",
            "port": 80,
            "users": [
              {
                "alterId": 0,
                "encryption": "",
                "flow": "",
                "id": "dc64073d-f617-4b4d-a175-b46f759d91a0",
                "level": 8,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "headers": {
            "Host": "user2.networkstoreid.asia"
          },
          "path": "/vmess"
        }
      },
      "tag": "Indonesia"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "netflix.com",
          "vidio.com",
          "dana.id",
          "geosite:google",
          "geosite:netflix"
        ],
        "network": "tcp,udp",
        "outboundTag": "Indonesia"
      },
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END

cat> /root/.routingtrojan << END
PROTOCOL="TROJAN"
HOST="${DOMAIN}"
UUID="${uuid}"
PATH="/trojan"
END
}

JsonParadisTMP() {
  local uuid=$(cat /proc/sys/kernel/random/uuid)
cat> "$JSON_PATH/paradis/paradis.json" << END
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService",
      "HandlerService",
      "RoutingService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "port": 55,
      "listen":"0.0.0.0",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/worryfree"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "port": 1055,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "email": "${NAME_CLIENT}"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
            "serviceName": "vmess"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "dokodemo-door",
        "settings": {
          "address": "127.0.0.1"
        },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    },
    {
      "mux": {
        "concurrency": 8,
        "enabled": false
      },
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "user2.networkstoreid.asia",
            "port": 80,
            "users": [
              {
                "alterId": 0,
                "encryption": "",
                "flow": "",
                "id": "dc64073d-f617-4b4d-a175-b46f759d91a0",
                "level": 8,
                "security": "auto"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "headers": {
            "Host": "user2.networkstoreid.asia"
          },
          "path": "/vmess"
        }
      },
      "tag": "Indonesia"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "netflix.com",
          "vidio.com",
          "dana.id",
          "geosite:google",
          "geosite:netflix"
        ],
        "network": "tcp,udp",
        "outboundTag": "Indonesia"
      },
      {
        "type": "field",
        "ip": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
END

cat> /root/.routingvmess << END
PROTOCOL="VMESS"
HOST="${DOMAIN}"
UUID="${uuid}"
PATH="/vmess"
END
}

FirewallACCEPT() {
  if [[ -z $(iptables -L | grep -w "58") ]]; then
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 58 -j ACCEPT
    iptables -I INPUT -m state --state NEW -m udp -p udp --dport 58 -j ACCEPT
  fi
  
  if [[ -z $(iptables -L | grep -w "57") ]]; then
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 57 -j ACCEPT
    iptables -I INPUT -m state --state NEW -m udp -p udp --dport 57 -j ACCEPT
  fi
  
  if [[ -z $(iptables -L | grep -w "55") ]]; then
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 55 -j ACCEPT
    iptables -I INPUT -m state --state NEW -m udp -p udp --dport 55 -j ACCEPT
  fi
  
  if [[ -z $(iptables -L | grep -w "54") ]]; then
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 54 -j ACCEPT
    iptables -I INPUT -m state --state NEW -m udp -p udp --dport 54 -j ACCEPT
  fi
  
  iptables-save > /etc/iptables.up.rules
  iptables-save > /etc/iptables/rules.v4
  netfilter-persistent save
  netfilter-persistent reload
}

MAIN() {
  if [[ ! -e /usr/sbin/potatonc ]]; then
    mkdir -p /usr/sbin/potatonc
  fi
  apt --fix-broken install -y
  DownloadFileXrayLoop
}

MAIN