#!/bin/bash

HOST="root@192.168.125.2"
PASSWORD="root"

for i in 1 2 3 4 5
do
gnome-terminal --title="dog-$i" -- bash -c "
sshpass -p $PASSWORD ssh -o StrictHostKeyChecking=no $HOST
exec bash
"
done
