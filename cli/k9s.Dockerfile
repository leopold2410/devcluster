# k9s + kubectl matching the cluster version, pinned via ../versions.env (update-setup-01).
# Built locally: the official derailed/k9s image lags behind releases and ships an old kubectl.
FROM alpine:3.23.3
ARG K9S_VERSION
ARG KUBECTL_VERSION
ARG TARGETARCH
RUN set -eux; \
    apk add --no-cache ca-certificates curl vim; \
    cd /tmp; \
    curl -fsSLO "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/checksums.sha256" \
        | grep " k9s_Linux_${TARGETARCH}.tar.gz\$" | sha256sum -c -; \
    tar -xzf "k9s_Linux_${TARGETARCH}.tar.gz" -C /usr/local/bin k9s; \
    rm "k9s_Linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /usr/local/bin/kubectl" \
        | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    # Home for any UID (the container runs as the host user); .local is backed by a named volume
    mkdir -p /home/k9s/.local; \
    chmod -R 1777 /home/k9s
ENV HOME=/home/k9s \
    EDITOR=vim
ENTRYPOINT ["k9s"]
