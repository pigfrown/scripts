#!/usr/bin/env bash
#
#
prop=${1:-recordsize}
dataset=${2:-shrew/subvol-106-disk-0}
echo $prop $dataset
zfs get -H -o value $prop $dataset
