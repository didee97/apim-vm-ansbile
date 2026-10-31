# Ubuntu 22.04 "VM" for the test lab: systemd as PID 1 + SSH + sudo user
FROM ubuntu:22.04
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv openssh-server sudo python3 iproute2 ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && useradd -m -u 1000 -s /bin/bash ubuntu \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
 && mkdir -p /home/ubuntu/.ssh && chown ubuntu:ubuntu /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh \
 && systemctl enable ssh \
 && systemctl mask getty.target systemd-logind.service console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
