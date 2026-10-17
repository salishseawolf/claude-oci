# syntax=docker/dockerfile:1

FROM debian:trixie-slim

LABEL org.opencontainers.image.source="https://github.com/salishseawolf/claude-oci"
LABEL org.opencontainers.image.authors="tgwolf@salishseawolf.com"

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install dependencies, Node.js 24.x, Podman (see "Podman config" comment
#    below), and configure npm — one apt-get update/install pass for all of
#    it, since a second update elsewhere would just re-fetch the same index.
#    - gcc + libc6-dev: the host-side C linker every Rust build script needs,
#      even for projects whose Rust toolchain comes from mise
#    - uidmap + fuse-overlayfs + passt: nested rootless Podman with the
#      faster fuse-overlayfs storage when /dev/fuse is passed in (see
#      entrypoint.sh)
#    - procps + jq: ps/free and JSON inspection for debugging sessions
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl fuse-overlayfs gcc git jq libc6-dev passt \
        crun podman procps slirp4netns uidmap && \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    # set npm prefix to avoid sudo
    mkdir -p /root/.npm-global && \
    npm config set prefix /root/.npm-global && \
    rm -rf /var/lib/apt/lists/*

ENV PATH=/root/.npm-global/bin:$PATH

# 2. Install mise-en-place
RUN curl https://mise.run | sh && \
    mkdir -p /root/.local/share/mise/shims

# Shims (not just `mise activate`) are required so mise-managed tools are
# resolvable by non-interactive subprocesses, e.g. Claude Code's own Bash
# tool calls, which don't source .bashrc or trigger the activate hook.
ENV PATH=/root/.local/share/mise/shims:/root/.local/bin:$PATH

# 3. Install Claude Code (no sudo)
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# 4. Copy small, frequently-edited local files last (COPY creates destination
#    directories on its own) so editing any one of them doesn't invalidate
#    the apt/curl/npm layers above and force them to re-run.
COPY config.toml /root/.config/mise/config.toml
COPY .bashrc /root/.bashrc
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
COPY agents/mise.md /root/.claude/commands/

# Podman config: vfs storage driver + crun, close to the Gitea CI runner, so
# nested builds (e.g. testing this repo's own Containerfiles from inside the
# running image) work rootless. Nested `podman run` additionally needs the
# outer-container flags in README's "Nested Podman and screenshots".
COPY containers/storage.conf /etc/containers/storage.conf
COPY containers/storage-overlay.conf /etc/containers/storage-overlay.conf
COPY containers/containers.conf /etc/containers/containers.conf
# Nested `podman build` RUN steps use chroot isolation instead of a crun
# container. With the nested profile's SELinux type container_engine_t, crun
# can't mount the tmpfs buildah uses to mask /sys/devices/virtual/powercap
# ("mount `tmpfs` to `sys/devices/virtual/powercap`: Permission denied").
# Same setting as quay.io/podman/stable.
ENV BUILDAH_ISOLATION=chroot

WORKDIR /workspace

# 5. Entrypoint to pass through arguments, preserving env
ENTRYPOINT ["/entrypoint.sh"]

