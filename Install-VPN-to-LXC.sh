 #!/bin/bash
apt update -y
apt upgrade -y
sudo apt-get install openvpn
cd /etc/openvpn
sudo wget https://www.privateinternetaccess.com/openvpn/openvpn.zip
sudo unzip openvpn.zip
sudo openvpn uk_manchester.ovpn
