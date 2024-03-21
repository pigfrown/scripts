#!/usr/bin/env bash

CONTAINER=${1:-nothing}

if (( $CONTAINER < 100 || $CONTAINER > 999 )) ; then
   echo "Must pass a valid container ID (you passed $CONTAINER)"
fi

pct exec $CONTAINER -- bash -c "apt update && apt upgrade -y && apt autoremove -y"


