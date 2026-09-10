#!/bin/bash
#
# Install dev tools: fix .so symlinks, zsh + plugins, opencode, htop/nvtop
#
set -e

# --- 0) Fix versioned .so files then ldconfig (must run first: broken .so breaks apt/dpkg) ---
sudo bash -c '
for file in /usr/local/lib/*.so.*; do
  # If it is a regular file and NOT a symbolic link
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    mv "$file" "${file}.1"
  fi
done
ldconfig
'

sudo apt update --allow-releaseinfo-change
sudo apt install -y zsh git curl wget htop nvtop

# --- 1) zsh + plugins (git, z, zsh-syntax-highlighting, zsh-autosuggestions) ---
export RUNZSH=no
export CHSH=no
export KEEP_ZSHRC=yes

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Installing oh-my-zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  echo "oh-my-zsh already installed."
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# zsh-syntax-highlighting
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
else
  echo "zsh-syntax-highlighting already installed."
fi

# zsh-autosuggestions
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
  git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
else
  echo "zsh-autosuggestions already installed."
fi

# Enable plugins in ~/.zshrc (git, z, zsh-syntax-highlighting, zsh-autosuggestions)
# 'z' is bundled with oh-my-zsh, 'git' too.
if [ -f "$HOME/.zshrc" ]; then
  if grep -q "^plugins=" "$HOME/.zshrc"; then
    sed -i 's/^plugins=.*/plugins=(git z zsh-syntax-highlighting zsh-autosuggestions)/' "$HOME/.zshrc"
  else
    echo 'plugins=(git z zsh-syntax-highlighting zsh-autosuggestions)' >> "$HOME/.zshrc"
  fi
else
  echo 'plugins=(git z zsh-syntax-highlighting zsh-autosuggestions)' > "$HOME/.zshrc"
fi

# --- 1b) CUDA env (nvidia-smi, nvcc, ncu, torch) for zsh ---
# setup_cuda.sh is env-only (no apt/sudo): it fixes PATH/LD_LIBRARY_PATH for the
# preinstalled CUDA 12.8 toolkit + driver binaries in /opt/bin on Kaggle.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CUDA_SETUP="$SCRIPT_DIR/setup_cuda.sh"
if [ -f "$CUDA_SETUP" ]; then
  chmod +x "$CUDA_SETUP" || true
  # Persist for future zsh sessions (idempotent, ~/.zshrc only).
  # --quiet --no-verify keeps new-shell startup instant (no torch import per prompt).
  if ! grep -Fq "cuda-setup (Kaggle)" "$HOME/.zshrc" 2>/dev/null; then
    {
      echo ''
      echo '# >>> cuda-setup (Kaggle) >>>'
      echo "[ -f \"$CUDA_SETUP\" ] && source \"$CUDA_SETUP\" --quiet --no-verify"
      echo '# <<< cuda-setup (Kaggle) <<<'
    } >> "$HOME/.zshrc"
    echo "CUDA env wired into ~/.zshrc."
  else
    echo "CUDA env already wired into ~/.zshrc."
  fi
  # Also configure the current session (best-effort; never fail the install).
  # shellcheck disable=SC1090
  source "$CUDA_SETUP" --quiet --no-verify || true
else
  echo "WARNING: $CUDA_SETUP not found, skipping CUDA zsh wiring."
fi

# Make zsh the default shell
ZSH_PATH="$(command -v zsh)"
if [ "$SHELL" != "$ZSH_PATH" ]; then
  echo "Setting default shell to $ZSH_PATH ..."
  sudo chsh -s "$ZSH_PATH" "$(whoami)" || chsh -s "$ZSH_PATH" || true
  # Also ensure root default if running with sudo context (best-effort)
  sudo chsh -s "$ZSH_PATH" root || true
else
  echo "zsh is already the default shell."
fi

# --- 2) opencode (persistent in /kaggle/working) ---
# Kaggle gives a fresh system disk every session, but /kaggle/working persists.
# The upstream installer hardcodes INSTALL_DIR=$HOME/.opencode/bin with no env
# override, so we install with HOME=/kaggle/working (+ --no-modify-path) to land
# the binary in persistent storage, then symlink + wire PATH on every boot.
OPENCODE_PERSIST_DIR="/kaggle/working/.opencode/bin"
OPENCODE_PERSIST_BIN="$OPENCODE_PERSIST_DIR/opencode"

if [ -d "/kaggle/working" ]; then
  # Prepend persistent dir first so a reused binary is found on fresh boots
  # where $HOME/.opencode/bin does not exist yet.
  case ":$PATH:" in
    *":$OPENCODE_PERSIST_DIR:"*) ;;
    *) export PATH="$OPENCODE_PERSIST_DIR:$PATH" ;;
  esac

  if [ -x "$OPENCODE_PERSIST_BIN" ]; then
    echo "opencode already installed in persistent dir ($OPENCODE_PERSIST_BIN), reusing."
  elif ! command -v opencode &> /dev/null; then
    echo "Installing opencode to persistent dir ($OPENCODE_PERSIST_DIR)..."
    HOME=/kaggle/working curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
  else
    echo "opencode already installed ($(command -v opencode))."
  fi

  # Compat symlink: tools expecting the default $HOME/.opencode/bin keep working.
  if [ -e "$HOME/.opencode/bin" ] && [ ! -L "$HOME/.opencode/bin" ]; then
    echo "WARNING: $HOME/.opencode/bin exists as a real dir, leaving it in place."
  else
    mkdir -p "$HOME/.opencode"
    ln -sfn "$OPENCODE_PERSIST_DIR" "$HOME/.opencode/bin"
  fi

  # Add persistent dir to PATH in zsh (idempotent)
  if ! grep -Fq "$OPENCODE_PERSIST_DIR" "$HOME/.zshrc" 2>/dev/null; then
    echo "export PATH=\"$OPENCODE_PERSIST_DIR:\$PATH\"" >> "$HOME/.zshrc"
  fi
  # Also export for current session
  case ":$PATH:" in
    *":$OPENCODE_PERSIST_DIR:"*) ;;
    *) export PATH="$OPENCODE_PERSIST_DIR:$PATH" ;;
  esac
else
  # Non-Kaggle fallback: default ephemeral install.
  if ! command -v opencode &> /dev/null; then
    echo "Installing opencode..."
    curl -fsSL https://opencode.ai/install | bash
  else
    echo "opencode already installed."
  fi

  # Add opencode to PATH in zsh (idempotent)
  for BINDIR in "$HOME/.opencode/bin" "$HOME/.local/bin"; do
    if [ -d "$BINDIR" ] || [ "$BINDIR" = "$HOME/.opencode/bin" ]; then
      if ! grep -q "$BINDIR" "$HOME/.zshrc" 2>/dev/null; then
        echo "export PATH=\"$BINDIR:\$PATH\"" >> "$HOME/.zshrc"
      fi
    fi
  done
  # Also export for current session
  export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
fi

# Verify
if command -v opencode &> /dev/null; then
  echo "opencode: $(command -v opencode) ($(opencode --version 2>&1 | head -n1 || true))"
else
  echo "WARNING: opencode binary not found after install."
fi

# --- 3) htop and nvtop already installed above via apt ---
echo "htop version: $(htop --version 2>&1 | head -n1 || true)"
command -v nvtop &> /dev/null && echo "nvtop installed: $(command -v nvtop)" || echo "WARNING: nvtop binary not found after apt install."

echo "Done. Restart shell or run: exec zsh"
