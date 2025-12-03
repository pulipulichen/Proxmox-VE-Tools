#!/usr/bin/env bash

fio --filename=/dev/sda \
    --direct=1 --rw=read --bs=4k \
    --size=200G --numjobs=32 --runtime=600 \
    --group_reporting --name=file1 --time_based=1