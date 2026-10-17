# Claude Code OCI Container Images

Container images for running [Claude Code CLI](https://claude.ai/code) in containerized environments. Built with Podman/Docker and available in four variants.

## Images

### Base Image (`claude-code:latest`)
Minimal Debian-based image with Claude Code CLI and Node.js 24.x.

**Includes:**
- Debian Trixie Slim
- Node.js 24.x
- Claude Code CLI (`@anthropic-ai/claude-code`)
- Git
- mise (development environment manager)
- Podman (for nested builds, e.g. testing this repo's own Containerfiles from inside the running image — see [Nested Podman builds](#nested-podman-builds)), with `uidmap`, `fuse-overlayfs` and `passt`
- gcc + libc6-dev (the C linker Rust build scripts need, even when Rust itself comes from mise)
- procps, jq

**Built-in Claude agents:**
- `/mise` - Specialized agent for managing tools, tasks, and environments with mise

**Note:** mise is pre-configured and automatically activated in all shells, with auto-install enabled for seamless tool management. Its shims directory is also always on `PATH`, so tools stay resolvable even for Claude Code's own non-interactive Bash tool calls.

### Rust Development Image (`claude-code:rust`)
Extends the base image with a complete Rust development environment.

**Additional tools:**
- Rust stable toolchain (rustup)
- Cargo with rustfmt and clippy
- Development tools: cargo-watch, cargo-expand, cargo-audit
- Build essentials (gcc, pkg-config, libssl-dev)

### Rust + WebAssembly Image (`claude-code:rust-wasm`)
Extends the Rust image with WebAssembly tooling for building WASM applications.

**Additional tools:**
- wasm-pack (WebAssembly package builder)
- basic-http-server (static file server for testing WASM applications)

**Additional Claude agents:**
- `/webserver` - Specialized agent for managing basic-http-server during WASM development

### Web + GPU Image (`claude-code:web-gpu`)
Extends the base image (not the Rust one: projects pin their own toolchains in `mise.toml`) with a headless browser for visually checking web and WebGPU projects.

**Additional tools:**
- Chromium, driven by `webshot` (a small Node + playwright-core script)
- WebGPU with no GPU through Chromium's bundled SwiftShader, plus Mesa Vulkan drivers for a real GPU passed in with `--device /dev/dri`
- vulkan-tools (`vulkaninfo --summary`) for diagnosing adapters

**Additional Claude agents:**
- `/webshot` - Screenshot a page after optional clicks/drags/keys, capture its console output, and read the PNG back

`webshot --probe` reports which Chromium flag profile exposes a WebGPU adapter in the current environment (`mise run test:webshot` from the host).

## Building

### Prerequisites
- Podman or Docker installed
- [mise](https://mise.jdx.dev/) (optional, for task runner)

### Build with mise
```bash
# Build base image
mise run build

# Build Rust variant (automatically builds base image first)
mise run build:rust

# Build Rust + WASM variant (automatically builds base and rust images first)
mise run build:rust-wasm

# Build web + GPU variant (automatically builds base image first)
mise run build:web-gpu
```

### Build with Podman
```bash
# Build base image
podman build -t claude-code:latest .

# Build Rust variant
podman build -f Containerfile.rust -t claude-code:rust .

# Build Rust + WASM variant
podman build -f Containerfile.rust-wasm -t claude-code:rust-wasm .

# Build web + GPU variant
podman build -f Containerfile.web-gpu -t claude-code:web-gpu .
```

### Build with Docker
```bash
# Build base image
docker build -t claude-code:latest .

# Build Rust variant
docker build -f Containerfile.rust -t claude-code:rust .

# Build Rust + WASM variant
docker build -f Containerfile.rust-wasm -t claude-code:rust-wasm .
```

### Nested Podman builds

Every image includes Podman, configured with the `vfs` storage driver and `crun` runtime (`containers/storage.conf`, `containers/containers.conf`) — close to the unprivileged setup the Gitea CI runner uses (crun instead of runc because runc can't run nested containers with cgroups disabled). This means `podman build` works from inside a running container, e.g. to test-build this repo's own Containerfiles during development, without passing `--privileged` or any extra flags to the outer `podman run`/`docker run`:

```bash
podman run -it --rm -v $(pwd):/workspace claude-code:latest
# then, inside the container:
podman build -t claude-code:latest .
```

`vfs` trades away copy-on-write layer sharing for reliability in nested/unprivileged environments, so nested builds are slower and use more disk than a native overlay driver would.

When the container is started with `--device /dev/fuse`, `entrypoint.sh` switches Podman to `containers/storage-overlay.conf` (overlay via `fuse-overlayfs`, separate graphroot) by exporting `CONTAINERS_STORAGE_CONF`. Without it, the `vfs` default applies, which keeps CI unchanged.

Nested Podman does **not** work under the hardened flags used in the examples below (`--cap-drop=ALL`, `--security-opt=no-new-privileges`): with no capabilities, even creating a user namespace fails. Use the [nested Podman and screenshots profile](#nested-podman-and-screenshots) instead. From the host, `mise run test:nested` checks that a container runs inside the base image.

## Usage

### Running Claude Code
Mount your project directory to `/workspace`:

```bash
# Using Podman
podman run -it --rm \
  -v $(pwd):/workspace \
  claude-code:latest

# Using Docker
docker run -it --rm \
  -v $(pwd):/workspace \
  claude-code:latest
```

Claude Code will prompt you to authenticate interactively on first run.

**Note for SELinux environments (Fedora, RHEL, CentOS):** Add the `:z` flag to volume mounts to properly label them:
```bash
podman run -it --rm \
  -v $(pwd):/workspace:z \
  claude-code:latest
```

### Persisting Configuration

To persist Claude Code authentication and settings across container restarts, create a named volume for the configuration directory:

```bash
# Create a named volume for Claude configuration
podman volume create claude-config

# Use it when running the container
podman run -it --rm \
  -v claude-config:/root/.claude \
  -v $(pwd):/workspace \
  claude-code:latest

# On SELinux systems
podman run -it --rm \
  -v claude-config:/root/.claude:z \
  -v $(pwd):/workspace:z \
  claude-code:latest
```

This avoids having to re-authenticate each time you start a new container.

### Running with Rust Environment
```bash
podman run -it --rm \
  -v $(pwd):/workspace \
  claude-code:rust
```

### Examples

The examples below add some hardening and quality-of-life flags:

- `--init` reaps zombie processes; `--security-opt=no-new-privileges` and `--cap-drop=ALL` shrink the container's privileges.
- **No `--userns=keep-id`.** With rootless Podman, container UID 0 already maps to your host user, so files written to the `:z` bind mount land owned by *you*, not `root`. Adding `--userns=keep-id` instead runs the process as your non-root UID, which this image (built entirely as `root`, home under `/root`) can't start under.
- `-v "claude-home:/root/.claude"` persists authentication between runs. Podman seeds the named volume from the image on first use, owned by container UID 0 (your host user under rootless Podman). Run the container the same way each time; if you ever change the UID mapping (e.g. add `--userns=keep-id` or use `sudo podman`), delete the volume with `podman volume rm claude-home` and let it re-seed, or the old file ownership will trigger `EACCES` on `/root/.claude`.
- If you rely on [nested Podman builds](#nested-podman-builds), drop `--cap-drop=ALL` and `--security-opt=no-new-privileges` — rootless `podman build` needs the setuid `newuidmap`/`newgidmap` helpers.

#### Get help
```bash
podman run -it --rm claude-code:latest --help
```

#### Run Claude Code in current directory
```bash
podman run -it --rm \
  --hostname claude-code \
  --init \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -v "${PWD}:/workspace:z" \
  -v "claude-home:/root/.claude" \
  -w /workspace \
  -e TERM -e COLORTERM \
  --tz local \
  claude-code:latest
```

#### Work on a Rust project
```bash
podman run -it --rm \
  --hostname claude-code \
  --init \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -v "${PWD}:/workspace:z" \
  -v "claude-home:/root/.claude" \
  -w /workspace \
  -e TERM -e COLORTERM \
  --tz local \
  claude-code:rust
```

#### Work on a Rust WebAssembly project
```bash
podman run -it --rm \
  --hostname claude-code \
  --init \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -v "${PWD}:/workspace:z" \
  -v "claude-home:/root/.claude" \
  -w /workspace \
  -e TERM -e COLORTERM \
  --tz local \
  claude-code:rust-wasm
```

#### Develop WASM with live preview (with port mapping)
```bash
# Map container port 4000 to host port 8080
podman run -it --rm \
  --hostname claude-code \
  --init \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -v "${PWD}:/workspace:z" \
  -v "claude-home:/root/.claude" \
  -w /workspace \
  -e TERM -e COLORTERM \
  --tz local \
  -p 8080:4000 \
  claude-code:rust-wasm
```

Then from within Claude Code in the container, you can:
```bash
# Use the built-in web server management agent
/webserver

# Or manually run the server
basic-http-server -a 0.0.0.0:4000 ./pkg
```

#### Nested Podman and screenshots

For projects where Claude should build/run containers and screenshot the rendered app (`claude-code:web-gpu`). This drops `--cap-drop=ALL` and `no-new-privileges`, which nested Podman needs, and passes `/dev/fuse` for faster storage. Named volumes keep mise toolchains, the cargo registry, other caches, and nested Podman images between sessions:

```bash
podman run -it --rm \
  --hostname claude-code \
  --device /dev/fuse \
  --security-opt label=type:container_engine_t \
  --cap-add=SYS_ADMIN \
  -v "${PWD}:/workspace:z" \
  -v "claude-home:/root/.claude" \
  -v "claude-mise:/root/.local/share/mise" \
  -v "claude-cargo:/root/.cargo/registry" \
  -v "claude-cache:/root/.cache" \
  -v "claude-podman:/var/lib/containers" \
  -w /workspace \
  -e TERM -e COLORTERM \
  --tz local \
  claude-code:web-gpu
```

- Nested containers share this container's network (`netns = "host"` in `containers/containers.conf`), since a private network needs `/dev/net/tun`, and run without cgroups of their own (`cgroups = "disabled"`, using `crun`), since `/sys/fs/cgroup` is read-only here. They therefore get no resource limits of their own; the outer container stays the isolation boundary. Nested `podman build` runs `RUN` steps with `BUILDAH_ISOLATION=chroot`, since `container_engine_t` blocks the tmpfs mount buildah's default isolation uses to mask `/sys/devices/virtual/powercap`.
- `--security-opt label=type:container_engine_t` runs the container under the SELinux type `container-selinux` provides for container engines inside containers. On SELinux hosts (Fedora, RHEL) the default `container_t` blocks nested containers from mounting `/proc` (``crun: mount `proc` to `proc`: Permission denied``); `container_engine_t` allows it while keeping SELinux confinement and per-container MCS separation. Prefer it over `label=disable`, which also works but leaves the container unconfined (`spc_t`). Hosts without SELinux ignore it.
- No `--init`: Podman bind-mounts its init binary from the host at `/run/podman-init`, and `container_engine_t` isn't allowed to execute it (``exec container process `/run/podman-init`: Permission denied``). Without it, orphaned processes aren't reaped until the container exits, which is harmless for a session-length container.
- `--cap-add=SYS_ADMIN` lets nested Podman (rootful inside this container) mount `/dev/mqueue`, `/dev/pts` and `/proc` and set up namespaces. `--privileged` isn't needed.
- Add `--device /dev/dri` to let WebGPU use the host's real GPU (`webshot --profile hardware`).

**Security trade-offs of this profile.** The user namespace stays the main boundary: container root is your host user, never host root, and escaping to host root still takes a kernel exploit. What this profile gives up relative to the hardened one:

- `SYS_ADMIN` applies only inside your user namespace, but it unlocks extra syscalls in Podman's seccomp profile (`mount`, `unshare`, `setns`, ...), exposing much more kernel code. Several container-escape CVEs (e.g. CVE-2022-0185) needed exactly namespaced `SYS_ADMIN`. A successful escape lands as your host user, with everything that account can read: `~/.ssh`, kubeconfigs, browser profiles, git credentials. SELinux `container_engine_t` still limits that, which is why it's preferred over `label=disable`.
- `/dev/fuse` adds little on its own (FUSE is designed for unprivileged users), but FUSE is also a known primitive for making kernel race exploits reliable.
- Without `--cap-drop=ALL`/`no-new-privileges`, the container keeps Podman's default capability set and setuid binaries work, all scoped to the user namespace.
- This container runs untrusted code routinely: dependency build scripts, pulled images, and Chromium with `--no-sandbox` (webshot is meant for localhost dev servers).

Mitigations: use this profile only for sessions that need nested containers or screenshots, and keep the hardened profile as the default. For the strongest containment, run these containers as a dedicated host user (with its own sub-ID range) whose home holds no credentials, so even an escape reaches nothing sensitive.

## CI/CD

The repository includes two CI workflows, each with a `lint` job that checks all four Containerfiles with [hadolint](https://github.com/hadolint/hadolint) (`.hadolint.yaml`) on every push and pull request, followed by a `build-and-push` job — gated on `lint` passing and push events only — that builds, smoke-tests, and publishes all four images on pushes to `main`, `master`, or `test` branches:

- **Gitea Actions** (`.gitea/workflows/build-and-push.yml`) publishes to the Gitea Container Registry.
- **GitHub Actions** (`.github/workflows/build-and-push.yml`) publishes to the GitHub Container Registry (`ghcr.io`).

Images are tagged with:
- `:latest` / `:rust` / `:rust-wasm` / `:web-gpu` - Latest build from main branch
- `:{commit-sha}` / `:rust-{commit-sha}` / `:rust-wasm-{commit-sha}` / `:web-gpu-{commit-sha}` - Specific commit builds

## License

See the upstream [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for license information.
