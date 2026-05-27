#!/bin/bash
#
# Container Start Script for Prime Intellect pods built from the wrapper
# Dockerfile in this directory.
#
# Paste this verbatim into PI's "Container Start Script" field (Advanced
# section of the pod create form). PI populates $PUBLIC_KEY and $SSH_PORT
# at pod boot time; this script wires them into sshd and then runs sshd
# in the foreground as PID 1.

if [ ! -z "$PUBLIC_KEY" ]; then
    echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

if [ ! -z "$SSH_PORT" ]; then
    sed -i '/^#*Port /d' /etc/ssh/sshd_config
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

echo "Starting SSH server on port ${SSH_PORT:-22}"

exec /usr/sbin/sshd -D
