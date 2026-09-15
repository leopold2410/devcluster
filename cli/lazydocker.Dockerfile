# lazydocker + Docker CLI/Compose plugin, pinned via ../versions.env (update-setup-01).
# Built locally: the official lazyteam/lazydocker image hasn't been updated since 2022.
FROM alpine:3.23.3
ARG LAZYDOCKER_VERSION
ARG TARGETARCH
RUN set -eux; \
    apk add --no-cache ca-certificates curl docker-cli docker-cli-compose; \
    case "${TARGETARCH}" in \
        amd64) arch=x86_64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    file="lazydocker_${LAZYDOCKER_VERSION#v}_Linux_${arch}.tar.gz"; \
    cd /tmp; \
    curl -fsSLO "https://github.com/jesseduffield/lazydocker/releases/download/${LAZYDOCKER_VERSION}/${file}"; \
    curl -fsSL "https://github.com/jesseduffield/lazydocker/releases/download/${LAZYDOCKER_VERSION}/checksums.txt" \
        | grep " ${file}\$" | sha256sum -c -; \
    tar -xzf "${file}" -C /usr/local/bin lazydocker; \
    rm "${file}"; \
    # Home for any UID (the container runs as the host user); holds ~/.docker
    mkdir -p /home/lazydocker; \
    chmod 1777 /home/lazydocker
ENV HOME=/home/lazydocker
ENTRYPOINT ["lazydocker"]
