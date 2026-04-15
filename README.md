# nteract-dev-ami

Packer recipe for an Ubuntu-based dev AMI with toolchains for building [`nteract/desktop`](https://github.com/nteract/desktop).

## Contents

- Ubuntu 24.04, fully upgraded
- Build deps for Tauri + WebKit on Linux
- Node 22 (via nodesource), pnpm via corepack
- Rust 1.94.0 with rustfmt, clippy, cargo-binstall, tauri-cli, wasm-pack, sccache
- Python 3, uv, maturin
- Deno, GitHub CLI, Playwright system deps, Tailscale (installed, not configured)
- Claude Code CLI
- `nteract/desktop` and `rgbkrk/async-rust-lsp` pre-cloned
- A release build of `runtimed` and debug builds of `runt` + `mcpb-runt`, symlinked in `/usr/local/bin/`

## Bake

```bash
packer init .
packer build base.pkr.hcl
```

Requires an AWS credential source with EC2 + S3 (sccache) access and `iam:PassRole` for `packer-bake-profile`.
