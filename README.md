# ubuntu-ikev2-vpn
This script will install strongswan VPN on your Ubuntu 24 server. You'll be able to connect to your VPN server from MacOS without additional software.

Copy vpn.sh to your server, chmod +X vpn.sh, modify VPN_USER, VPN_PASS, run it.

Then open System Preferences on your MacBook (tested on Sonoma 14.7), VPN.

Click Add VPN Configuration -> IKEv2

Display name: My VPN
Server address: <PUBLIC_IP>
Remote ID: <PUBLIC_IP>

User authentication: Username
Username: <VPN_USER>
Password: <VPN_PASS>

Connect, enjoy.
