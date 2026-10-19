# Operator image: os-upgrade with kubectl, yq, kustomize and kubeconform, all pinned.
# Built from the dist tree: make image (runs make dist first).
FROM docker.io/library/ubuntu:24.04

ARG VERSION=dev
LABEL org.opencontainers.image.title="os-upgrade" \
      org.opencontainers.image.description="Ubuntu LTS upgrades with a pinned kernel on RKE2 nodes through the system-upgrade-controller" \
      org.opencontainers.image.source="https://github.com/Hector295/ubuntu-upgrade-plan" \
      org.opencontainers.image.version="$VERSION"

# ca-certificates: Rancher kubeconfigs often rely on a public CA.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY dist/os-upgrade/ /opt/os-upgrade/
COPY tools/bin/kubectl /usr/local/bin/kubectl
RUN ln -s /opt/os-upgrade/bin/os-upgrade /usr/local/bin/os-upgrade \
 && mkdir -p /work && chmod 0777 /work

# Any uid can run it (docker run --user): kubectl writes its cache under $HOME.
ENV HOME=/tmp
WORKDIR /work
ENTRYPOINT ["os-upgrade"]
CMD ["help"]
