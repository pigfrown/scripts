#!/usr/bin/env bash

function usage() {
	echo "Usage: $0 <source_port> <target_port>"
	exit 1
}

is_positive_integer() {
    re='^[0-9]+$'
    if [[ $1 =~ $re ]] && [ "$1" -gt 0 ]; then
        return 0  # It's a positive integer
    else
        return 1  # It's not a positive integer
    fi
}

src=${1:-x}
target=${2:-x}

if [ "$src" == x ] ; then
	usage
fi


if [ "$target" == x ] ; then
	usage
fi


if ! is_positive_integer "$src" ; then
	echo "Source must be a port (positive int)"
	usage
fi

if ! is_positive_integer "$target" ; then
	echo "Source must be a port (positive int)"
	usage
fi

# Redirect for external users
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 3000
iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports 3000
# Redirect for internal users
iptables -t nat -A OUTPUT -p udp --dport 443 -j REDIRECT --to-ports 3000
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-ports 3000

iptables-save
