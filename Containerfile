# Fedora-based image for the SELinux AI Policy Generator PoC.
# Run with scripts/podman_run.sh (privileged + systemd + SELinux mount).
FROM fedora:40

LABEL org.opencontainers.image.title="selinux-ai-poc"
LABEL org.opencontainers.image.description="SELinux AI policy generator proof of concept"

RUN dnf -y install \
    systemd \
    audit \
    policycoreutils \
    policycoreutils-python-utils \
    checkpolicy \
    setools-console \
    python3 \
    python3-pip \
    curl \
    procps-ng \
    which \
    && dnf clean all

# Hint for systemd inside OCI containers
RUN ln -sf /usr/lib/systemd/systemd /sbin/init
ENV container=oci

COPY generator/requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt

COPY scripts/container_entrypoint.sh /usr/local/bin/container_entrypoint.sh
RUN chmod +x /usr/local/bin/container_entrypoint.sh

WORKDIR /workspace

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/bin/container_entrypoint.sh"]
CMD ["/sbin/init"]
