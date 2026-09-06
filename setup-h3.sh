#!/usr/bin/env bash
set -euo pipefail

export COMFYUI_DIR=/workspace/ComfyUI
export MODELS_DIR="$COMFYUI_DIR/models"
export HF_HOME=/workspace/.cache/huggingface

# ---------------------------------------
# Persistent Python environment
# ---------------------------------------

export VENV_DIR=/workspace/h3-venv

create_venv() {
    echo "Creating persistent Python environment..."

    if ! python3 -m venv "$VENV_DIR"; then
        echo "ERROR: Could not create the Python virtual environment."
        echo "On Debian/Ubuntu, install venv support with:"
        echo "  apt-get update && apt-get install -y python3-venv"
        exit 1
    fi

    # Bootstrap pip explicitly and verify that the package is importable.
    "$VENV_DIR/bin/python" -m ensurepip --upgrade
    "$VENV_DIR/bin/python" -m pip install --upgrade pip
}

# A directory alone does not prove that the saved environment is usable.
# Check both its Python executable and its pip module before reusing it.
if [ ! -x "$VENV_DIR/bin/python" ] || \
   ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
    if [ -e "$VENV_DIR" ]; then
        BROKEN_VENV="${VENV_DIR}.broken-$(date +%Y%m%d-%H%M%S)"
        echo "Existing Python environment is incomplete or broken."
        echo "Moving it to: $BROKEN_VENV"
        mv "$VENV_DIR" "$BROKEN_VENV"
    fi

    create_venv
else
    echo "Using existing Python environment: $VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# Use this exact interpreter for all Python and pip operations. This avoids
# accidentally using a system-level pip executable.
PYTHON="$VENV_DIR/bin/python"
PIP=("$PYTHON" -m pip)

mkdir -p "$HF_HOME"

# ---------------------------------------
# Check PyTorch CUDA version
# ---------------------------------------

get_torch_cuda() {
    "$PYTHON" - <<'PY'
try:
    import torch
    print(torch.version.cuda or "")
except Exception:
    print("")
PY
}

echo "Checking PyTorch CUDA version..."
TORCH_CUDA=$(get_torch_cuda)

if [ "$TORCH_CUDA" != "13.0" ]; then
    echo "Current PyTorch CUDA version: ${TORCH_CUDA:-not installed}"
    echo "Installing PyTorch with CUDA 13.0 support..."

    "${PIP[@]}" uninstall -y torch torchvision torchaudio || true
    "${PIP[@]}" install \
        torch \
        torchvision \
        torchaudio \
        --index-url https://download.pytorch.org/whl/cu130

    echo "Verifying PyTorch..."

    "$PYTHON" - <<'PY'
import torch

print("PyTorch:", torch.__version__)
print("PyTorch CUDA:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(0))

if torch.version.cuda != "13.0":
    raise RuntimeError(
        f"Expected PyTorch CUDA 13.0, got {torch.version.cuda}"
    )
PY
else
