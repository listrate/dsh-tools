# syntax=docker/dockerfile:1
# DeepSeek Harness (dsh) agent runtime image.
#
# Everything here comes from public sources: the official Node image, Debian
# packages, the published @deepseek-ai/dsh npm package, official
# kubectl/kubelogin release binaries, the mise release tarball, and the
# artifacthub-mcp source repository.
#
# Nothing sensitive is baked in — no secrets, credentials, kubeconfigs,
# hostnames, domains or private-repository references. Runtime configuration
# (workspace path, public URL, API keys, tokens) is injected at deploy time.

ARG NODE_IMAGE=node:24-bookworm-slim

# ── stage 1: artifacthub-mcp (stdio MCP server, source build) ────────────────
FROM ${NODE_IMAGE} AS artifacthub-builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/alexw00/artifacthub-mcp . \
    && npm ci \
    && npm run build

# ── stage 2: dsh runtime ─────────────────────────────────────────────────────
FROM ${NODE_IMAGE}

ARG TARGETARCH=amd64
# Pinned DeepSeek Harness CLI version (published npm package).
ARG DSH_VERSION=0.2.0-rc.2
ARG MISE_VERSION=v2026.8.4
ARG KUBECTL_VERSION=v1.37.1
ARG KUBELOGIN_VERSION=v1.36.4

# Debian bookworm ships glibc 2.36, which covers the GLIBC <= 2.28 floor the
# harness publishes Linux artifacts against. Alpine/musl is *not* a tested
# upstream path, so this image stays glibc.
#
# bash        — the harness shell seam's default shell
# git, openssh-client — workspace clones and node access
# curl, ca-certificates — HTTPS egress (model API, GitHub, npm)
# jq, procps, unzip, tar, xz-utils — scripting and release archives
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        procps \
        tar \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# kubectl + kubelogin: the OIDC exec plugin a client-credentials kubeconfig
# shells out to when calling an OIDC-protected cluster.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ARCH=amd64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    chmod +x /usr/local/bin/kubectl; \
    curl -fsSL -o /tmp/kubelogin.zip \
      "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_linux_${ARCH}.zip"; \
    unzip -o -j /tmp/kubelogin.zip kubelogin -d /usr/local/bin; \
    chmod +x /usr/local/bin/kubelogin; \
    rm -f /tmp/kubelogin.zip; \
    kubectl version --client=true; \
    kubelogin --version

# mise — the workspace declares its CLI toolset in a mise config and installs
# it onto the shared volume at pod start. The glibc tarball is used because
# this image is Debian-based.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) MISE_ARCH=x64 ;; \
      arm64) MISE_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mise.tar.gz \
      "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${MISE_ARCH}.tar.gz"; \
    tar -xzf /tmp/mise.tar.gz -C /tmp; \
    find /tmp/mise/bin -maxdepth 1 -type f -exec mv {} /usr/local/bin/ \; ; \
    chmod +x /usr/local/bin/mise; \
    rm -rf /tmp/mise /tmp/mise.tar.gz; \
    mise --version

# DeepSeek Harness CLI (`dsh`) plus its web frontend bundle. node-pty ships a
# linux-x64 prebuild, so this install needs no compiler toolchain.
RUN npm install -g --no-audit --no-fund "@deepseek-ai/dsh@${DSH_VERSION}" \
    && dsh --version \
    && command -v dsh

# artifacthub-mcp (stdio, built from source in stage 1)
COPY --from=artifacthub-builder /src/dist /usr/local/share/artifacthub-mcp/dist

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
