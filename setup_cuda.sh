#!/usr/bin/env bash
#
# setup_cuda.sh — clean CUDA environment setup for Kaggle (via SSH)
#
# What it does (idempotent, no installs, no sudo, no existing-file edits
# unless you pass --persist):
#   1. Detects the pre-installed CUDA toolkit (/usr/local/cuda -> 12.8)
#   2. Fixes PATH so nvidia-smi, nvcc, ncu, nsight-compute are found
#   3. Fixes LD_LIBRARY_PATH so libcudart / CUPTI / driver libs resolve
#   4. Exports CUDA_HOME / CUDA_PATH / CUDACXX etc. for torch / extensions
#   5. Verifies: nvidia-smi, nvcc, torch.cuda, ncu
#
# Observed Kaggle image (Sep 2026):
#   Ubuntu 22.04, 2x Tesla T4 (sm_75), driver 580.159.04 (CUDA 13.0 compat)
#   Toolkit 12.8 at /usr/local/cuda-12.8, torch 2.10.0+cu128 (CUDA 12.8 build)
#   nvidia-smi lives in /opt/bin (NOT in default PATH over SSH)
#   driver libs in /usr/local/nvidia/lib64 (already in ldconfig)
#   Nsight Compute 2025.1.1 in /opt/nvidia/nsight-compute + /usr/local/cuda/bin/ncu
#
# Usage:
#   source /kaggle/working/remote-ssh-kaggle-vscode/setup_cuda.sh                 # setup + verify current shell
#   source /kaggle/working/remote-ssh-kaggle-vscode/setup_cuda.sh --quiet --no-verify  # fast load for ~/.zshrc
#   source /kaggle/working/remote-ssh-kaggle-vscode/setup_cuda.sh --persist       # + auto-source from ~/.bashrc and ~/.zshrc
#   bash /kaggle/working/remote-ssh-kaggle-vscode/setup_cuda.sh --verify          # check only, no env changes
#
# NOTE: you MUST `source` this script, not execute it, for the exports
# to persist in your SSH shell. Executing it runs verification in a subshell only.
#

# ---------------------------------------------------------------------------
# Guard: re-sourcing is safe.
# ---------------------------------------------------------------------------
# Don't use `set -e` here: this file is meant to be sourced, and `set -e`
# would leak into the user's interactive shell.
# shellcheck disable=SC2148

_CUDA_SETUP_QUIET=0
_CUDA_SETUP_VERIFY_ONLY=0
_CUDA_SETUP_NO_VERIFY=0
_CUDA_SETUP_PERSIST=0

for _arg in "$@"; do
  case "$_arg" in
    -q|--quiet)       _CUDA_SETUP_QUIET=1 ;;
    --verify|--check|--verify-only) _CUDA_SETUP_VERIFY_ONLY=1 ;;
    --no-verify|--no-check|--fast) _CUDA_SETUP_NO_VERIFY=1 ;;
    --persist)        _CUDA_SETUP_PERSIST=1 ;;
    -h|--help)
      sed -n '1,55p' "${BASH_SOURCE[0]:-$0}"
      # `return` when sourced, `exit` when executed
      return 0 2>/dev/null || exit 0
      ;;
    *) echo "setup_cuda.sh: unknown arg '$_arg' (allowed: --persist, --verify, --no-verify, --quiet, --help)" >&2 ;;
  esac
done

_cuda_log()  { [ "$_CUDA_SETUP_QUIET" -eq 0 ] && echo "[cuda-setup] $*" ; }
_cuda_ok()   { [ "$_CUDA_SETUP_QUIET" -eq 0 ] && echo "[cuda-setup] OK: $*" ; }
_cuda_warn() { echo "[cuda-setup] WARN: $*" >&2 ; }

# Prepend $2 to colon-separated var $1, no duplicates, no empty entries.
_cuda_prepend_unique() {
  local _var="$1" _dir="$2" _cur _new
  [ -d "$_dir" ] || return 0
  eval "_cur=\${$_var:-}"
  case ":${_cur}:" in
    *":${_dir}:"*) return 0 ;;  # already present
  esac
  _new="${_dir}${_cur:+:$_cur}"
  eval "export ${_var}=\"${_new}\""
}

# ---------------------------------------------------------------------------
# 1. Locate CUDA toolkit (prefer the /usr/local/cuda symlink so minor
#    upgrades keep working; fall back to versioned dirs, then to nvcc).
# ---------------------------------------------------------------------------
_CUDA_HOME_CANDIDATES=(
  "/usr/local/cuda"
  "/usr/local/cuda-12"
  "/usr/local/cuda-12.8"
  "/usr/local/cuda-13"
)
_detect_cuda_home() {
  local c
  for c in "${_CUDA_HOME_CANDIDATES[@]}"; do
    if [ -x "$c/bin/nvcc" ]; then echo "$c"; return 0; fi
  done
  # Fall back: nvcc already on PATH?
  if command -v nvcc >/dev/null 2>&1; then
    dirname "$(dirname "$(command -v nvcc)")"; return 0
  fi
  return 1
}

if [ "$_CUDA_SETUP_VERIFY_ONLY" -eq 0 ]; then
  if [ -n "${CUDA_HOME:-}" ] && [ -x "$CUDA_HOME/bin/nvcc" ]; then
    _CUDA_HOME="$CUDA_HOME"
  else
    _CUDA_HOME="$(_detect_cuda_home)" || _CUDA_HOME=""
  fi

  if [ -z "${_CUDA_HOME:-}" ]; then
    _cuda_warn "no CUDA toolkit found under /usr/local/cuda*. nvcc-dependent steps will fail."
    _cuda_warn "torch (pip cu128 wheels) may still work since it bundles its own CUDA runtime."
  else
    # Resolve symlink (/usr/local/cuda -> /etc/alternatives/cuda -> .../cuda-12.8)
    # for display only; keep CUDA_HOME as the stable symlink path.
    _CUDA_HOME_REAL="$(readlink -f "$_CUDA_HOME" 2>/dev/null || echo "$_CUDA_HOME")"
    export CUDA_HOME="$_CUDA_HOME"
    export CUDA_PATH="$_CUDA_HOME"
    export CUDA_ROOT="$_CUDA_HOME"
    export CUDACXX="$_CUDA_HOME/bin/nvcc"
    export CUDA_TOOLKIT_ROOT_DIR="$_CUDA_HOME"
    _cuda_log "CUDA_HOME=$_CUDA_HOME (real: $_CUDA_HOME_REAL)"
  fi

  # -------------------------------------------------------------------------
  # 2. PATH — toolkit binaries, driver binaries (nvidia-smi), Nsight Compute
  # -------------------------------------------------------------------------
  # Nsight Compute standalone install: pick newest versioned dir if present.
  _NSIGHT_DIR=""
  if ls -d /opt/nvidia/nsight-compute/* >/dev/null 2>&1; then
    # version-sort, take last (e.g. 2025.1.1)
    _NSIGHT_DIR="$(ls -d /opt/nvidia/nsight-compute/* 2>/dev/null | sort -V | tail -n 1)"
  fi

  [ -n "${_CUDA_HOME:-}" ] && _cuda_prepend_unique PATH "$_CUDA_HOME/bin"
  _cuda_prepend_unique PATH "/opt/bin"                      # nvidia-smi & friends on Kaggle
  [ -n "$_NSIGHT_DIR" ] && _cuda_prepend_unique PATH "$_NSIGHT_DIR"
  export PATH

  # -------------------------------------------------------------------------
  # 3. LD_LIBRARY_PATH — runtime libs.
  #    (Most are already covered by /etc/ld.so.conf.d/{000_cuda,nvidia}.conf,
  #    but SSH shells + pip-built extensions + CUPTI/profiling reliably need it.)
  # -------------------------------------------------------------------------
  # Prepend lowest-priority first so highest-priority ends up first.
  # Desired order: toolkit > driver (/usr/local/nvidia/lib64) > system.
  _cuda_prepend_unique LD_LIBRARY_PATH "/usr/lib/x86_64-linux-gnu"
  _cuda_prepend_unique LD_LIBRARY_PATH "/usr/local/nvidia/lib64"
  if [ -n "${_CUDA_HOME:-}" ]; then
    # Modern layout: targets/x86_64-linux/lib is the real lib dir;
    # lib64 is usually a symlink to it. Add both (prepend = harmless dup-guard).
    # Prepend lib64 first so targets/... (real dir) wins.
    _cuda_prepend_unique LD_LIBRARY_PATH "$_CUDA_HOME/lib64"
    _cuda_prepend_unique LD_LIBRARY_PATH "$_CUDA_HOME/targets/x86_64-linux/lib"
    # CUPTI lives under targets/... on this image; legacy path kept for compat.
    _cuda_prepend_unique LD_LIBRARY_PATH "$_CUDA_HOME/extras/CUPTI/lib64"
    # Forward-compat stub libs (only used at link time, harmless at runtime).
    if [ -d "$_CUDA_HOME/compat" ]; then
      # NOTE: do NOT prepend compat ahead of the real driver libs in
      # /usr/local/nvidia/lib64 — the real driver must win. Append instead.
      case ":${LD_LIBRARY_PATH:-}:" in
        *"$_CUDA_HOME/compat"*) ;;
        *) export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$_CUDA_HOME/compat" ;;
      esac
    fi
  fi
  export LD_LIBRARY_PATH

  # Helpful for nvcc / extension builds (torch.utils.cpp_extension / cffi).
  if [ -n "${_CUDA_HOME:-}" ]; then
    _cuda_prepend_unique CPATH "$_CUDA_HOME/targets/x86_64-linux/include"
    [ -d "$_CUDA_HOME/include" ] && _cuda_prepend_unique CPATH "$_CUDA_HOME/include"
    export CPATH
  fi

  # Number of visible GPUs sanity hint (do not override a user-set value).
  if [ -z "${CUDA_DEVICE_ORDER:-}" ]; then
    export CUDA_DEVICE_ORDER="PCI_BUS_ID"
  fi

  _cuda_ok "PATH=$PATH"
  _cuda_ok "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<empty, using ldconfig>}"
fi

# ---------------------------------------------------------------------------
# 4. Verify — same checks whether sourced normally or with --verify.
#    Skipped entirely with --no-verify / --fast (for instant ~/.zshrc loads).
# ---------------------------------------------------------------------------
if [ "$_CUDA_SETUP_NO_VERIFY" -eq 0 ]; then
_CUDA_SETUP_FAIL=0

_verify_cmd() {  # _verify_cmd <label> <cmd...>
  local _label="$1"; shift
  if command -v "$1" >/dev/null 2>&1; then
    _cuda_ok "$_label: $(command -v "$1")"
    return 0
  else
    _cuda_warn "$_label: '$1' not found on PATH"
    _CUDA_SETUP_FAIL=1
    return 1
  fi
}

if [ "$_CUDA_SETUP_QUIET" -eq 0 ]; then
  echo "[cuda-setup] ---- verification ----"
fi

_verify_cmd "nvidia-smi" nvidia-smi && nvidia-smi -L 2>&1 | sed 's/^/[cuda-setup]   /'
_verify_cmd "nvcc" nvcc && nvcc --version 2>&1 | sed 's/^/[cuda-setup]   /'

if command -v ncu >/dev/null 2>&1; then
  _cuda_ok "ncu: $(command -v ncu)"
  ncu --version 2>&1 | head -n 5 | sed 's/^/[cuda-setup]   /'
else
  _cuda_warn "ncu (Nsight Compute CLI) not found — profiling with ncu unavailable"
  _CUDA_SETUP_FAIL=1
fi

# PyTorch check: bundled cu128 runtime must see the GPUs even if the
# system toolkit has issues, so report it separately and clearly.
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PYEOF' 2>&1 | sed 's/^/[cuda-setup]   /'
try:
    import torch
    print(f"torch {torch.__version__} (built for CUDA {torch.version.cuda})")
    print(f"torch.cuda.is_available() = {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"device_count = {torch.cuda.device_count()}")
        for i in range(torch.cuda.device_count()):
            print(f"gpu[{i}] = {torch.cuda.get_device_name(i)} "
                  f"cap={torch.cuda.get_device_capability(i)}")
        torch.zeros(1, device="cuda")  # smoke-test allocation
        print("cuda allocation smoke test: PASS")
    else:
        print("HINT: torch cannot see a GPU — check nvidia-smi above and "
              "that you are on a GPU-backed Kaggle session.")
except ImportError:
    print("torch is not installed in this python3.")
except Exception as e:
    print(f"torch CUDA check FAILED: {type(e).__name__}: {e}")
PYEOF
else
  _cuda_warn "python3 not found — skipping torch check"
fi

if [ "$_CUDA_SETUP_FAIL" -ne 0 ]; then
  _cuda_warn "verification finished WITH WARNINGS (see above)."
else
  _cuda_ok "verification finished — nvidia-smi, nvcc, ncu, torch all look good."
fi
fi # end --no-verify guard

# ---------------------------------------------------------------------------
# 5. Optional persistence for future SSH sessions.
#    Appends a single `source` line to ~/.bashrc and ~/.zshrc (no duplicates).
# ---------------------------------------------------------------------------
if [ "$_CUDA_SETUP_PERSIST" -eq 1 ] && [ "$_CUDA_SETUP_VERIFY_ONLY" -eq 0 ]; then
  _SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
  _SOURCE_LINE="source \"$_SCRIPT_PATH\"  # cuda-setup (Kaggle)"
  for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    touch "$_rc"
    if grep -Fq "cuda-setup (Kaggle)" "$_rc" 2>/dev/null; then
      _cuda_log "persist: already present in $_rc"
    else
      printf '\n%s\n' "$_SOURCE_LINE" >> "$_rc"
      _cuda_ok "persist: appended source line to $_rc"
    fi
  done
  _cuda_log "persist: future SSH shells will auto-configure CUDA. Re-login or run:"
  _cuda_log "persist:   source ~/.bashrc   # or: source ~/.zshrc"
fi

# If the user executed instead of sourcing, exports die with the subshell.
if [ "$_CUDA_SETUP_VERIFY_ONLY" -eq 0 ] && [ "$_CUDA_SETUP_QUIET" -eq 0 ]; then
  if [ -z "${BASH_SOURCE[0]:-}" ] && [ -z "${ZSH_EVAL_CONTEXT:-}" ]; then
    # Neither bash-source nor zsh context detectable — likely executed.
    :
  elif ! (return 0 2>/dev/null); then
    echo "[cuda-setup] NOTE: script was EXECUTED, not sourced — exports apply only to that subshell." >&2
    echo "[cuda-setup] NOTE: run  source \"${BASH_SOURCE[0]:-$0}\"  to configure THIS shell." >&2
  fi
fi

# Clean up private vars (keep the exported env).
unset _CUDA_SETUP_QUIET _CUDA_SETUP_VERIFY_ONLY _CUDA_SETUP_NO_VERIFY _CUDA_SETUP_PERSIST
unset _CUDA_HOME _CUDA_HOME_REAL _NSIGHT_DIR _arg _rc _SCRIPT_PATH _SOURCE_LINE
unset -f _cuda_log _cuda_ok _cuda_warn _cuda_prepend_unique _detect_cuda_home _verify_cmd 2>/dev/null || true
