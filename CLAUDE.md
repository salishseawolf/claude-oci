# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository provides OCI container images for running Claude Code CLI in containerized environments. It includes four image variants built on top of each other:

1. **Base image** (`claude-code:latest`) - Debian Trixie Slim + Node.js 24.x + Claude Code CLI + Podman + gcc
2. **Rust image** (`claude-code:rust`) - Base + Rust toolchain + cargo development tools
3. **Rust WASM image** (`claude-code:rust-wasm`) - Rust + wasm-pack + basic-http-server + custom `/webserver` agent
4. **Web + GPU image** (`claude-code:web-gpu`) - Base + Chromium (SwiftShader WebGPU) + Mesa Vulkan drivers + `webshot` + custom `/webshot` agent

## Build System

### Building Images

Use mise task runner (preferred) or Podman/Docker directly:

```bash
# Build base image
mise run build

# Build Rust variant (automatically builds base first)
mise run build:rust

# Build Rust + WASM variant (automatically builds base and rust first)
mise run build:rust-wasm

# Build web + GPU variant (automatically builds base first)
mise run build:web-gpu
```

Or with Podman directly:
```bash
podman build -t claude-code:latest .
podman build -f Containerfile.rust -t claude-code:rust .
podman build -f Containerfile.rust-wasm -t claude-code:rust-wasm .
podman build -f Containerfile.web-gpu -t claude-code:web-gpu .
```

### Image Architecture

The images follow a layered architecture:
- `Containerfile` → base image with Claude Code
- `Containerfile.rust` → FROM base, adds Rust tooling
- `Containerfile.rust-wasm` → FROM rust, adds WASM tools + custom agents
- `Containerfile.web-gpu` → FROM base (not rust: its projects pin toolchains in their own `mise.toml`), adds Chromium, Mesa Vulkan drivers, playwright-core, `tools/webshot`

The mise tasks enforce this dependency chain automatically.

## Custom Claude Code Agents

This repository includes custom Claude Code agents that provide specialized capabilities:

### `/mise` Agent (all images)
Available in the base image and all variants. Provides comprehensive assistance with:
- Tool version management (installing, switching, upgrading runtimes)
- Task execution and definition (TOML-based and file-based tasks)
- Configuration management (creating and modifying mise.toml)
- Environment setup and troubleshooting

Location: `agents/mise.md` → `/root/.claude/commands/mise.md`

### `/webserver` Agent (rust-wasm image only)
Available only in the rust-wasm image. Provides specialized capabilities for:
- Managing basic-http-server during WASM development
- Starting, stopping, and checking server status
- Port configuration and troubleshooting

Location: `agents/webserver.md` → `/root/.claude/commands/webserver.md`

### `/webshot` Agent (web-gpu image only)
Screenshots pages (including WebGPU content) with headless Chromium via `tools/webshot`, optionally after mouse/keyboard actions, and prints the page's console output. `webshot --probe` reports which Chromium flag profile exposes a WebGPU adapter.

Location: `agents/webshot.md` → `/root/.claude/commands/webshot.md`

### Adding New Agents

When modifying or adding new agents:
- Place agent definition files in `agents/` directory
- Copy them to `/root/.claude/commands/` in the appropriate Containerfile
- Agents are markdown files with YAML frontmatter describing their purpose
- Use existing agents as templates for structure and patterns
- Agents copied in the base image are inherited by all variants

## CI/CD Pipeline

Two parallel workflows, kept in sync by convention, each with a `lint` job followed by a `build-and-push` job:

- **Gitea Actions** (`.gitea/workflows/build-and-push.yml`) — uses Podman, pushes to the Gitea Container Registry.
- **GitHub Actions** (`.github/workflows/build-and-push.yml`) — uses Docker/Buildx, pushes to `ghcr.io`.

Both trigger on push and pull_request to `main`, `master`, or `test`.

Key workflow details:
- `lint` job runs [hadolint](https://github.com/hadolint/hadolint) against all four Containerfiles (matrix job), using the shared `.hadolint.yaml` config. Runs on every push and pull request.
- hadolint's version is declared in `mise.toml` (`[tools] hadolint`), installed in CI via `jdx/mise-action@v2` — bump the version there, not in the workflow files.
- `build-and-push` job `needs: lint` and is gated to `github.event_name == 'push'` (no publishing from pull requests).
- Builds all four images in dependency order: base, rust, rust-wasm, and web-gpu, with a `--version` smoke test after each build (plus `chromium --version` for web-gpu), before any registry login or push.
- Tags images with both `:latest`/`:rust`/`:rust-wasm`/`:web-gpu` and commit SHA (`:$SHA`, `:rust-$SHA`, `:rust-wasm-$SHA`, `:web-gpu-$SHA`).
- Local build tags are always `claude-code:*`, independent of this repo's own name, because `Containerfile.rust` and `Containerfile.rust-wasm` hardcode `FROM claude-code:...`. The GitHub workflow builds locally with Buildx's `load: true` to preserve this, then separately tags/pushes the `ghcr.io/<owner>/<repo>` (lowercased) names.
- The GitHub workflow uses `docker/setup-buildx-action` to get a `docker-container` builder, but **only for the base image build** (`cache-from`/`cache-to: type=gha,scope=base` — the `gha` cache backend needs that driver; the default `docker` driver only supports `inline`). That driver runs BuildKit in its own isolated container with no view of the host Docker Engine's image store, which breaks a later `FROM claude-code:...` referencing a `load: true`'d local image (buildx tries a registry pull instead and fails, since `claude-code` doesn't exist on Docker Hub). **Confirmed in CI**: buildx's `build-contexts` `docker-image://` input, buildx's documented workaround for pointing a `FROM` at a locally-loaded image, does **not** help here — it still resolves via registry. So don't reach for `build-contexts` again for this; it was tried and failed in a live run. The actual fix: the base image's `FROM debian:trixie-slim` is a public image with no local-chain dependency, so it's the only one of the three builds safe to run on the docker-container/GHA-cache builder. A `docker buildx use default` step after the base build switches back to the plain `docker`-driver builder (which does share the engine's image store) before building `Containerfile.rust`/`Containerfile.rust-wasm` — those two get no GHA cache, just the working local-chain build.
- `cargo install` compiles from source; `Containerfile.rust`/`Containerfile.rust-wasm` use `cargo binstall` instead (installed via the official `cargo-bins/cargo-binstall` release script) so cargo-watch/cargo-expand/cargo-audit/wasm-pack/basic-http-server fetch prebuilt binaries where upstream publishes them, falling back to source compilation only when they don't.
- `Containerfile`'s apt/npm/mise layers are intentionally ordered before the small local-file `COPY`s (`config.toml`, `.bashrc`, `entrypoint.sh`, `agents/mise.md`, `containers/*.conf`) so editing one of those files doesn't invalidate the slower package-install layers. Keep new `COPY`s of small repo files last for the same reason, and keep apt packages consolidated into the single `RUN apt-get update && apt-get install ...` block rather than adding a second `apt-get update` elsewhere in the file.
- Gitea pushes using the `PACKAGE_REGISTRY_TOKEN` secret; GitHub pushes using the built-in `GITHUB_TOKEN` (requires the repo's Actions settings to grant it package write access).

Whenever a Containerfile changes (`Containerfile`, `Containerfile.rust`, `Containerfile.rust-wasm`, `Containerfile.web-gpu`), run hadolint locally before committing, mirroring the CI `lint` job: `mise install` (installs the version pinned in `mise.toml`) then `hadolint --config .hadolint.yaml <file>` for each changed file. Fix findings or extend `.hadolint.yaml`'s `ignored` list with a reasoning comment, rather than letting CI catch it.

If modifying either workflow:
- Keep the `lint` → `build-and-push` structure and the `.hadolint.yaml` ignore list in sync between both files unless there's a reason for them to diverge.
- Podman configuration (Gitea runner) uses custom `storage.conf` and `containers.conf` for rootless builds
- The VFS storage driver is slower but more compatible with CI environments
- Build steps reference `github.event.repository.name` for image naming

## Testing Images

After building, test images by mounting a project directory to `/workspace`:

```bash
# Test base image
podman run -it --rm -v $(pwd):/workspace claude-code:latest

# Test Rust image
podman run -it --rm -v $(pwd):/workspace claude-code:rust

# Test WASM image with port mapping (container port 4000 → host port 8080)
podman run -it --rm -v $(pwd):/workspace -p 8080:4000 claude-code:rust-wasm
```

On SELinux systems (Fedora, RHEL, CentOS), add `:z` to volume mounts: `-v $(pwd):/workspace:z`

## Important Notes

- All images use `/workspace` as the working directory
- The entrypoint is `/entrypoint.sh` which activates mise and launches Claude Code, so container arguments pass directly to Claude Code
- **mise is pre-activated**: The mise environment is automatically activated via both the entrypoint wrapper and `.bashrc` for interactive shells, and mise's shims directory (`/root/.local/share/mise/shims`) is permanently on `PATH` via the base Containerfile. The shims are what matter for Claude Code itself: its Bash tool spawns non-interactive subprocesses that never source `.bashrc` or trigger the `mise activate` hook, so without the shims on `PATH`, tools installed mid-session (e.g. via `mise use`) would be invisible to subsequent tool calls
- **mise global configuration**: Located at `/root/.config/mise/config.toml` with auto-install enabled and telemetry disabled
- Environment paths are configured for npm global packages (`/root/.npm-global/bin`), mise (`/root/.local/bin`), and Rust cargo (`/root/.cargo/bin`)
- The rust image includes development tools: cargo-watch, cargo-expand, cargo-audit
- The WASM image's webserver agent expects basic-http-server to bind to `0.0.0.0:4000` by default
- **Nested Podman storage switches on `/dev/fuse`**: `entrypoint.sh` exports `CONTAINERS_STORAGE_CONF=/etc/containers/storage-overlay.conf` (fuse-overlayfs, separate graphroot so a persisted vfs store isn't reopened with the wrong driver) when the container has `/dev/fuse`; otherwise the vfs `storage.conf` applies. `containers.conf` sets `[containers] netns = "host"` (a private nested network needs `/dev/net/tun`, which the outer container lacks) and `cgroups = "disabled"` (the outer container's `/sys/fs/cgroup` is read-only; needs crun, runc rejects it). Nested Podman fails under the README's hardened `--cap-drop=ALL`/`no-new-privileges` flags, and also needs `--cap-add=SYS_ADMIN` (nested Podman runs rootful and must mount proc/mqueue/devpts and create namespaces; scoped to the user namespace under rootless Podman) plus, on SELinux hosts, `--security-opt label=type:container_engine_t` (default `container_t` can't mount `/proc` for nested containers; `container_engine_t` allows it and keeps confinement and MCS separation, unlike `label=disable`, which also works but runs unconfined as `spc_t`). README's "Security trade-offs" covers what this profile gives up. The base image sets `BUILDAH_ISOLATION=chroot`: under `container_engine_t`, crun can't mount buildah's tmpfs mask over `/sys/devices/virtual/powercap` in build `RUN` steps. Shared UTS/IPC/user/cgroup namespaces, `unmask=/proc/*` and a root sub-ID range were each tried and shown unnecessary once SYS_ADMIN was added; `mise run test:nested` verifies it from the host
- **`Containerfile.rust` appends `/root/.cargo/bin` to `PATH`** (after mise's shims) so a project's mise-pinned Rust wins over the image's `stable` toolchain in non-interactive shells
- **Podman is included in every image** for nested builds (e.g. test-building this repo's own Containerfiles from inside the running container). It's configured via `containers/storage.conf` (`vfs` driver) and `containers/containers.conf` (`crun` runtime, since runc rejects `cgroups = "disabled"`; `cgroupfs` manager) to match the CI runner's unprivileged setup otherwise — no `--privileged` or extra host capabilities needed
