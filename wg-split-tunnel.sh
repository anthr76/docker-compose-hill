#!/bin/bash
#
# Script to create a split tunnel wireguard interface that will only tunnel a specific
# Docker network through wireguard. All other traffic will not be vpn'ed.
# 
# All credit to Reddit user /u/BrodyBuster from /r/WireGuard
#
# Script will:
#
# 	1. 	Create the proper route through the vpn for the docker network only.
#   2. 	Create route so local network can still reach the vpn'ed network. This ensures
#      	the WebGUIs are still accessible from the LAN for any of the vpn'ed containers and
#		that the containers can talk to each other	
#   3. 	Create a blackhole route to keep traffic from leaking if the wireguard Interface
#      	goes down for any reason.
#   4. 	Generate the boot configuration file using wireguard.sh config
#
# Usage wireguard.sh <up|down|config>
#
##########################################################################################
# Requirements:
#
# 1. Wireguard module installed on host. You can use this container to compile the module
#    1in a docker container to avoid having to install gcc etc on the host IF YOU ARE USING
#    1DEBIAN BUSTER. For any other distro choose your own method.
#    https://github.com/cmulk/wireguard-docker
#    
#    Use the following docker command:
#    	docker run -it --rm --cap-add sys_module -v /lib/modules:/lib/modules \
#        cmulk/wireguard-docker:buster install-module
#
# 2. Wireguard configuration in /etc/wireguard (DNS and Address need to be commented out)
#
# Sample wg0.conf file
#       [Interface]
#       PrivateKey = <key>
#       ListenPort = 51820
#       #DNS = 1.1.1.1             # Comment this line out if it's there
#       #Address = w.x.y.z/24      # Comment this line out if it's there
#
#       [Peer]
#       PublicKey = <key>
#       AllowedIPs = 0.0.0.0/0
#       Endpoint = a.b.c.d:443
#       PersistentKeepalive = 25
#
# 3. Resolvfconf package
#
# 4. Docker
##########################################################################################
# Instructions:
#
# Fill in the name of the docker network that needs to be vpn'ed (DOCKER_NET). If the
# docker network hasn't been created, the script will create the network with the given
# name and subnet 10.3.0.0/16.
#
# Run the script <wireguard.sh config> and it will create the boot configuration in
# /etc/network/interfaces.d/<interface>. This will restore the interface and routes
# after a reboot.
#
# To bring the interface up and create the tunnel: wireguard.sh up
#
# To bring the interface back down use <wireguard.sh down>. This will delete the wireguard
# interface but keep the blackhole route, so that any running containers won't leak and
# use the host LAN interface to reach the internet.
#
# Create a docker compose file to use the docker network similar to this:
# transmission:
#    image: linuxserver/transmission
#    container_name: transmission
#    environment:
#      - PUID=1001
#      - PGID=1001
#      - TZ=America/New_York
#      - TRANSMISSION_WEB_HOME=/combustion-release/
#    volumes:
#      - /<volume>:/downloads:rw
#      - /<volume>:/watch:rw
#      - /<volume>:/config:rw
#      - /etc/localtime:/etc/localtime:ro
#    ports:
#      - 9091:9091
#      - 51413:51413
#      - 51413:51413/udp
#    restart: unless-stopped
#    logging:
#      driver: "json-file"
#      options:
#        max-size: "5m"
#    networks:
#      - vpn
# networks:
#  vpn:
#    external:
#      name: docker-vpn0
##########################################################################################
## Set variables
# Name of the docker network to route through wireguard
# This network will be created if it does not exist using 10.30.0.0/16
DOCKER_NET_NAME="docker-vpn0"
# Name of wireguard interface to create
DEV_NAME="wg1"
##########################################################################################
# Nothing to edit below this line
# Get IP addresses and subnets needed
DOCKER_NET=`docker network inspect $DOCKER_NET_NAME | grep Subnet | awk '{print $2}' | sed 's/[",]//g'`
INTERFACE_IP=`grep Address /etc/wireguard/$DEV_NAME.conf | awk '{print $3}' | cut -d/ -f1`
ENDPOINT_IP=`grep Endpoint /etc/wireguard/$DEV_NAME.conf | awk '{print $3}' | cut -d: -f1`
FILE="/etc/network/interfaces.d/$DEV_NAME"

tecreset=$(tput sgr0)

set_ok (){ echo -e -n "[ \E[0;32m  OK  $tecreset ] "; }

set_failed (){ echo -e -n "[ \E[0;31mFAILED$tecreset ] "; }

up (){
	while [ -z "$DOCKER_NET" ]; do
		set_failed; echo "Network: $DOCKER_NET_NAME. Attempt to create ..."
		docker network create $DOCKER_NET_NAME --subnet 10.30.0.0/16 -o "com.docker.network.driver.mtu"="1420"
		DOCKER_NET=`docker network inspect $DOCKER_NET_NAME | grep Subnet | awk '{print $2}' | sed 's/[",]//g'`
    done
	set_ok; echo "Network: $DOCKER_NET_NAME"
	
	CMD="sysctl -w net.ipv4.conf.all.rp_filter=2"
	echo -n "`$CMD > /dev/null 2>&1`"; set_ok; echo -n $CMD
	
	CMD="ip link add $DEV_NAME type wireguard"
	echo "`$CMD > /dev/null 2>&1`"  
	CHECK=`ip addr | grep $DEV_NAME`
	if [[ -z $CHECK ]]; then
       	set_failed; echo "$CMD"
       	exit 1
	fi
	set_ok; echo "$CMD"
		
	CMD="wg setconf $DEV_NAME /etc/wireguard/$DEV_NAME.conf"
	if [[ ! -f "/etc/wireguard/$DEV_NAME.conf" ]]; then
    	set_failed; echo "$CMD"
       	exit 1
	fi
  	echo -n "`$CMD > /dev/null 2>&1`" 
  	set_ok; echo "$CMD"
  	
  	CMD="ip addr add $INTERFACE_IP dev $DEV_NAME"	
	echo -n "`$CMD > /dev/null 2>&1`" 
	CHECK=`ip addr | grep $INTERFACE_IP`
	if [[ -z $CHECK ]]; then
       	set_failed; echo "$CMD"
       	exit 1
	fi
  	set_ok; echo "$CMD"

	CMD="ip link set mtu 1420 up dev $DEV_NAME"
	echo -n "`$CMD > /dev/null 2>&1`"; set_ok; echo $CMD
	
	CMD="ip link set up dev $DEV_NAME"
	echo -n "`$CMD`"
  	CHECK=`ip addr | grep $DEV_NAME`
  	if [[ $CHECK != *"state UNKNOWN"* ]]; then
    	set_failed; echo "$CMD"
    	exit 1
	fi
  	set_ok; echo "$CMD"
	
	CMD="ip rule add from $DOCKER_NET table 200"
	CHECK=`ip rule show`
    while [[ $CHECK != *"lookup 200"* ]]; do
    	set_failed; echo  "$CMD"
    	echo -n "`$CMD`"
		CHECK=`ip rule show`
	done
    set_ok; echo "$CMD"
	
	CMD="ip route add blackhole default metric 3 table 200"
	CHECK=`ip route show table 200`
	while [[ $CHECK != *"blackhole"* ]]; do
		set_failed; echo "$CMD"
		echo -n "`$CMD`"
		CHECK=`ip route show table 200`
	done
	set_ok; echo "$CMD"
	
	CMD="ip route add default via $INTERFACE_IP metric 2 table 200"
	CHECK=`ip route show table 200`
    while [[ $CHECK != *"$INTERFACE_IP"* ]]; do
		set_failed; echo "$CMD"
        echo -n "`$CMD`"
        CHECK=`ip route show table 200`
    done
	set_ok; echo "$CMD"
	
	CMD="ip rule add table main suppress_prefixlength 0"
	CHECK=`ip rule show`
    while [[ $CHECK != *"suppress_prefixlength"* ]]; do
		set_failed; echo "$CMD"
		echo -n "`$CMD`"
    	CHECK=`ip rule show`
	done
    set_ok; echo "$CMD"
	
	IP=`docker run -ti --rm --net=docker-vpn0 appropriate/curl https://api.ipify.org`
	if [[ $IP == $ENDPOINT_IP ]]; then
		set_ok; echo "Connected to $ENDPOINT_IP"
	else
		set_failed; echo "Failed to connect to $ENDPOINT_IP"
	fi
}

down(){
  	CMD="ip link del dev $DEV_NAME"
	echo -n "`$CMD > /dev/null 2>&1`" 
	CHECK=`ip addr | grep $DEV_NAME`
	if [[ ! -z $CHECK ]]; then
       	set_failed; echo "$CMD"
	fi
  	set_ok; echo "$CMD"

	CMD="ip rule add from $DOCKER_NET table 200"
	CHECK=`ip rule show`
    while [[ $CHECK != *"lookup 200"* ]]; do
    	set_failed; echo  "$CMD"
    	echo -n "`$CMD`"
		CHECK=`ip rule show`
	done
    set_ok; echo "$CMD"
	
	CMD="ip route add blackhole default metric 3 table 200"
	CHECK=`ip route show table 200`
	while [[ $CHECK != *"blackhole"* ]]; do
		set_failed; echo "$CMD"
		echo -n "`$CMD`"
		CHECK=`ip route show table 200`
	done
	set_ok; echo "$CMD"
	
	IP=`docker run -ti --rm --net=docker-vpn0 appropriate/curl https://api.ipify.org`
	if [[ $IP == *"Could not resolve host"*  ]]; then
		set_ok; echo "Blackhole active"
	else
		set_failed; echo "Blackhole NOT active!"
	fi
}

# clean this up to prompt for overwrite
create(){
	#while [[ ! -f "$FILE" ]]; do
	#	set_failed; echo "Create Boot Config: /etc/network/interfaces.d/$DEV_NAME. Attempt to create ..."
		/bin/cat <<-EOM >$FILE
		auto $DEV_NAME
		iface $DEV_NAME inet manual
		pre-up ip route flush table 200
		pre-up ip rule add from $DOCKER_NET table 200
		pre-up ip rule add table main suppress_prefixlength 0
		pre-up ip route add blackhole default metric 3 table 200
		pre-up ip link add dev $DEV_NAME type wireguard
		pre-up wg setconf $DEV_NAME /etc/wireguard/$DEV_NAME.conf
		pre-up ip address add $INTERFACE_IP dev $DEV_NAME
		pre-up sysctl -w net.ipv4.conf.all.rp_filter=2
		pre-up ip link set mtu 1420 up dev $DEV_NAME
		ip link set up dev $DEV_NAME
		post-up /bin/bash -c "printf 'nameserver %s\n' '1.1.1.1' | resolvconf -a tun.$DEV_NAME -m 0 -x"
		post-up ip route add default via $INTERFACE_IP metric 2 table 200
		# del interface when network goes down
		post-down ip link del dev $DEV_NAME
		EOM
	#done
	/bin/cat $FILE
	echo "________________________________________________________________________________"
	set_ok; echo "Boot Config Created: /etc/network/interfaces.d/$DEV_NAME"
}

status(){
	CMD="ip route add blackhole default metric 3 table 200"
	CHECK=`ip route show table 200`
	while [[ $CHECK != *"blackhole"* ]]; do
		set_failed; echo "$CMD"
		echo -n "`$CMD`"
		CHECK=`ip route show table 200`
	done
	set_ok; echo "$CMD"
	
	IP=`docker run -ti --rm --net=docker-vpn0 appropriate/curl https://api.ipify.org`
	if [[ $IP == $ENDPOINT_IP ]]; then
		set_ok; echo "Connected to $ENDPOINT_IP"
	else
		set_failed; echo "Failed to connect to $ENDPOINT_IP"
	fi
}

command="$1"
shift

case "$command" in
    up) up "$@" ;;
    down) down "$@" ;;
    create) create "$@" ;;
    status) status "$@" ;;
    *) echo "Usage: $0 up|down|create|status" >&2; exit 1 ;;
esac