Enter#!/bin/bash
clear
echo -e "\033[38;5;135m╭────────────────────────────────────────────────────────╮\033[0m"
echo -e "\033[38;5;135m│\033[0m            \033[38;5;51mEDUFWESH ENTERPRISE SECURE LOADER\033[0m           \033[38;5;135m│\033[0m"
echo -e "\033[38;5;135m╰────────────────────────────────────────────────────────╯\033[0m"

IP=$(curl -s -4 ifconfig.me)
echo -e "\n\033[1;33m[*] Authenticating IP: \033[1;37m$IP\033[0m"

# Your Secure Cloudflare Vault Gateway
VAULT_URL="https://vault-gateway.edufwesh.workers.dev/"

# Attempt to download from the secure vault straight into temp storage
wget -qO /tmp/edufwesh-installer "$VAULT_URL"

# Verify if Cloudflare served a valid executable Linux binary (ELF)
if ! file /tmp/edufwesh-installer | grep -q "ELF"; then
    echo -e "\n\033[1;31m[!] ACCESS DENIED: Unauthorized Server IP.\033[0m"
    echo -e "\033[0;33mPlease click 'Whitelist VPS IP' in the Edufwesh Master Bot to unlock the installer.\033[0m"
    rm -f /tmp/edufwesh-installer
    exit 1
fi

chmod +x /tmp/edufwesh-installer
echo -e "\033[1;32m[+] Authentication successful! Decrypting payload...\033[0m\n"

# Execute the heavily encrypted installation binary
/tmp/edufwesh-installer

# Annihilate the binary immediately after the script finishes
rm -f /tmp/edufwesh-installer
