# nteract-dev-ami

Packer recipes for AMIs that build [`nteract/desktop`](https://github.com/nteract/desktop).

Two recipes:

- **`base.pkr.hcl`** - Linux (Ubuntu 24.04). Source for Linux labs.
- **`windows.pkr.hcl`** - Windows Server 2022. Source for winlabs.

## Linux (`base.pkr.hcl`)

- Ubuntu 24.04, fully upgraded
- Build deps for Tauri + WebKit on Linux
- Node 22 (via nodesource), pnpm via corepack
- Rust 1.94.0 with rustfmt, clippy, cargo-binstall, tauri-cli, wasm-pack, sccache
- Python 3, uv, maturin
- Deno, GitHub CLI, Playwright system deps, Tailscale (installed, not configured)
- Claude Code CLI
- `nteract/desktop` and `rgbkrk/async-rust-lsp` pre-cloned
- A release build of `runtimed` and debug builds of `runt` + `mcpb-runt`, symlinked in `/usr/local/bin/`

## Windows (`windows.pkr.hcl`)

- Windows Server 2022 English Full Base
- Chocolatey + git, gh, NASM, rust-ms (rustup + stable-msvc), nodejs-lts
- Visual Studio 2022 Build Tools with the C++ workload (cl.exe, link.exe, Windows SDK)
- pixi (env manager)
- pnpm + wasm-pack (GitHub release binaries)
- OpenSSH Server enabled, default shell PowerShell
- `nteract/desktop` pre-cloned at `C:\dev\desktop`

Per-boot user-data on a winlab launched from this AMI just adds the sandbox
admin user, drops your GitHub keys, joins Tailscale, and runs `git pull` on
the cloned repo.

## Bake

```bash
packer init .
packer build base.pkr.hcl       # Linux
packer build windows.pkr.hcl    # Windows
```

Both recipes require an AWS credential source with EC2 + S3 (sccache) access
and `iam:PassRole` for `packer-bake-profile`. lab-maker's IAM role grants
all of this; lab-maker drives both bakes on systemd timers (Linux every 7h,
Windows every 13h).
