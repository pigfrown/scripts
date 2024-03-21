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
iptables -t nat -A PREROUTING -p tcp --dport "$src" -j REDIRECT --to-ports "$target"
iptables -t nat -A PREROUTING -p udp --dport "$src" -j REDIRECT --to-ports "$target"

iptables-save > /etc/rules/rules.v4
