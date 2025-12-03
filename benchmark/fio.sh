#!/usr/bin/env bash

fio --direct=1 --rw=randrw --ioengine=libaio --bs=4k --rwmixread=100 \
    --filename=/dev/sda:/dev/sdb --iodepth=128 --numjobs=128 -runtime=600 \
    --time_based --group_reporting --name=fiotest --output=fiotest.txt