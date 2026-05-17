#!/bin/bash
# Runs as cloud-init user_data on the packer bake instance.
# Installs system deps and toolchains, pre-clones source repos, and warms
# sccache with a release build.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/ami-build.log) 2>&1
echo "=== nteract-dev-ami bake starting ==="

# Wait out any concurrent apt holder (cloud-init first-boot, unattended-upgrades)
APT_OPT="-o DPkg::Lock::Timeout=600"

apt-get $APT_OPT update
apt-get $APT_OPT upgrade -y
apt-get $APT_OPT install -y \
  build-essential clang curl direnv git unzip jq pkg-config \
  libssl-dev libgtk-3-dev libwebkit2gtk-4.1-dev libxdo-dev \
  libayatana-appindicator3-dev librsvg2-dev tmux xvfb \
  webkit2gtk-driver gcc-mingw-w64-x86-64 nasm git-lfs \
  python3 python3-venv python3-dev \
  sqlite3 \
  ripgrep fd-find hyperfine \
  cmake cppzmq-dev libzmq3-dev libsodium-dev gnuplot-nox

# Ubuntu ships fd as `fdfind` to avoid a name conflict with an older
# unrelated package. Symlink to `fd` so muscle memory + scripts work.
ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get $APT_OPT install -y nodejs
corepack enable

# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get $APT_OPT update -qq
apt-get $APT_OPT install -y gh

# Tailscale (installed but not configured — consumers auth at lab-provision time)
curl -fsSL https://tailscale.com/install.sh | sh

# Playwright system deps
npx playwright install-deps

# Rust toolchain (as ubuntu). 1.94.0 is the default; 1.94.1 is also
# installed because the OMQ smoke path in zmq.rs perf labs pins that
# patch (`cargo +1.94.1`). flamegraph rides along with the other
# cargo-binstalled tools — needs `perf` (already present) at runtime.
sudo -u ubuntu bash <<'RUSTEOF'
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.94.0
  source "$HOME/.cargo/env"
  rustup component add rustfmt clippy
  rustup toolchain install 1.94.1 --profile minimal
  curl -fsSL https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
  cargo binstall -y tauri-cli wasm-pack sccache flamegraph
RUSTEOF

# vite.plus
sudo -u ubuntu bash -c 'curl -fsSL https://vite.plus | bash'

# Python tooling
curl -LsSf https://astral.sh/uv/install.sh | sudo -u ubuntu sh
sudo -u ubuntu bash -c 'export PATH="$HOME/.local/bin:$PATH" && uv tool install maturin'

# Deno
sudo -u ubuntu bash -c 'curl -fsSL https://deno.land/install.sh | sh'

# Claude Code CLI
sudo -u ubuntu bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# sccache S3 config — needed before the warming build below
sudo -u ubuntu mkdir -p /home/ubuntu/.config/sccache
cat > /home/ubuntu/.config/sccache/config <<'SCCACHEEOF'
[cache.s3]
bucket = "nteract-sccache"
region = "us-east-1"
no_credentials = false
SCCACHEEOF
chown -R ubuntu:ubuntu /home/ubuntu/.config/sccache

# Clone public source repos (HTTPS — no auth needed)
sudo -u ubuntu bash -c '
  mkdir -p ~/projects
  git clone https://github.com/nteract/nteract.git ~/projects/nteract || true
  git clone https://github.com/rgbkrk/async-rust-lsp.git ~/projects/async-rust-lsp || true
  cd ~/projects/nteract && direnv allow
'

# Warm sccache + produce nightly binaries
sudo -u ubuntu bash <<'BUILDEOF' || true
set -euo pipefail
. "$HOME/.cargo/env"
export PATH="$HOME/.local/bin:$PATH"
. "$HOME/.vite-plus/env" 2>/dev/null || true
export RUSTC_WRAPPER=sccache
cd ~/projects/nteract
vp install
cargo xtask build
cargo build --release -p runtimed
BUILDEOF

# Stash nightly binaries where the launcher expects them
sudo -u ubuntu bash <<'DAEMONEOF' || true
set -euo pipefail
NIGHTLY_BIN="$HOME/.local/share/runt-nightly/bin"
mkdir -p "$NIGHTLY_BIN"
cd ~/projects/nteract
cp target/release/runtimed "$NIGHTLY_BIN/runtimed-nightly"
cp target/debug/runt "$NIGHTLY_BIN/runt-nightly"
cp target/debug/mcpb-runt "$NIGHTLY_BIN/mcpb-runt-nightly"
chmod +x "$NIGHTLY_BIN"/*-nightly
DAEMONEOF
for bin in runt-nightly runtimed-nightly mcpb-runt-nightly; do
  ln -sf "/home/ubuntu/.local/share/runt-nightly/bin/$bin" "/usr/local/bin/$bin"
done

# Per-instance directories (consumers drop files into these at provision time)
sudo -u ubuntu mkdir -p \
  /home/ubuntu/.config/quillbox/roles \
  /home/ubuntu/.config/quillbox/mcp \
  /home/ubuntu/.config/systemd/user \
  /home/ubuntu/.config/nteract-nightly \
  /home/ubuntu/.claude/agents \
  /home/ubuntu/.claude \
  /home/ubuntu/bin

# Tidy
apt-get clean
rm -rf /var/lib/apt/lists/*

# Success marker — packer's post-boot shell provisioner tests for this.
touch /var/log/cloud-init-ami-build-done
echo "=== nteract-dev-ami bake complete ==="
