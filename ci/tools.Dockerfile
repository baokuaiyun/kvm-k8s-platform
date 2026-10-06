# CI 构建工具镜像：git/tar/oras/cosign（供 GitLab CI build 阶段使用）
FROM alpine:3.20
ARG http_proxy
ARG https_proxy
ARG no_proxy
RUN apk add --no-cache git tar bash curl ca-certificates \
 && curl -sL "https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz" | tar xz -C /usr/local/bin oras \
 && curl -sL "https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64" -o /usr/local/bin/cosign \
 && chmod +x /usr/local/bin/cosign
ENTRYPOINT ["/bin/bash"]
