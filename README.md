# dsh-tools

Container image for the **DeepSeek Harness** (`dsh`) agent runtime:
`ghcr.io/listrate/dsh-tools`.

The image bundles the harness CLI plus the tooling its workspace needs — git,
OpenSSH, kubectl, kubelogin, mise, and the [artifacthub-mcp][artifacthub-mcp]
stdio server — on `node:24-bookworm-slim`.

[artifacthub-mcp]: https://github.com/alexw00/artifacthub-mcp

## What is in the image

| Component | Source |
| --- | --- |
| Base | official `node:24-bookworm-slim` (glibc) |
| Harness CLI | pinned `@deepseek-ai/dsh` npm package |
| Scripting/tooling | Debian packages: bash, git, openssh-client, curl, jq, procps, tar, unzip, xz-utils |
| kubectl | official `dl.k8s.io` release binary |
| kubelogin | `int128/kubelogin` release binary (OIDC exec plugin) |
| mise | `jdx/mise` glibc release tarball |
| artifacthub-mcp | source build from `alexw00/artifacthub-mcp` |

Nothing sensitive is baked in. There are no secrets, credentials, kubeconfigs,
hostnames, domains or private-repository references anywhere in this repository
or its image layers — runtime configuration and credentials are injected at
deploy time.

## Running it

With no arguments the entrypoint serves the harness Web UI (`dsh web`) from
`$DSH_WORKSPACE` and keeps the container alive as long as the server runs:

```sh
docker run --rm -p 8080:8080 \
  -e DEEPSEEK_API_KEY=... \
  -e DSH_WORKSPACE=/workspace \
  -e DSH_PUBLIC_URL=https://agent.example.com \
  -v "$PWD:/workspace" \
  ghcr.io/listrate/dsh-tools:latest
```

Environment variables the entrypoint reads:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DSH_WORKSPACE` | `/workspace` | directory the harness launches from (the workspace root) |
| `DSH_PUBLIC_URL` | *(unset)* | browser-facing root; the startup URL is rewritten to it |
| `DSH_URL_FILE` | `$HOME/.dsh-web-url` | where the authenticated URL is persisted |
| `DSH_LOG_FILE` | `/tmp/dsh-web.log` | captured server log |

The harness requires a one-time **tokenized visit**: the first page load must
carry the launch token printed as `dsh web: <url>?token=...` (also written to
`$DSH_URL_FILE`), which exchanges it for a signed session cookie. The token is
minted per process; the cookie survives restarts as long as `$DSH_HOME` is
persistent.

Arguments are passed through unchanged, so the image doubles as a general
harness CLI:

```sh
docker run --rm -v "$PWD:/workspace" ghcr.io/listrate/dsh-tools:latest \
  dsh --profile headless "run the tests"
```

Deployment-specific configuration (profile patches, model keys, cluster
credentials, allowed browser authorities) lives in the consuming deployment
repository, never here.

## Tags

- `dsh-<harness-version>-<build>` (e.g. `dsh-0.2.0-rc.2-1`) — one immutable tag
  per build; consumers should pin this tag. `<build>` increments when a rebuild
  keeps the same harness version.
- `latest` — most recent build of `main`; convenient, not reproducible.

## Building

```sh
docker build --build-arg DSH_VERSION=0.2.0-rc.2 -t dsh-tools:local .
```

The `build-and-push` workflow builds `linux/amd64` and pushes to GHCR on every
push to `main`. Renovate tracks the pinned upstream versions in the Dockerfile.
