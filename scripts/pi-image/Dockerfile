# Thin SSH-enabled wrapper around slimerl/slime:latest for Prime Intellect.
#
# Prime Intellect's pod runtime requires images to ship openssh-server and the
# PI-specific sshd config; the upstream slime image does not. This wrapper
# adds exactly what PI needs and nothing more.
#
# Build + push (see scripts/pi_runbook.md for full instructions):
#   docker build -t ramneetsingh/slime-ssh:latest scripts/pi-image
#   docker push ramneetsingh/slime-ssh:latest
#
# The companion start.sh in this directory must be pasted verbatim into PI's
# "Container Start Script" field (Advanced section of the pod create form) —
# it is NOT set as the image ENTRYPOINT/CMD per PI's documented contract.

FROM slimerl/slime:latest

RUN apt-get update && \
    apt-get install -y openssh-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd && \
    ssh-keygen -A

RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
