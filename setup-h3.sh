#!/usr/bin/env bash
set -euo pipefail

export COMFYUI_DIR=/workspace/ComfyUI
export MODELS_DIR="$COMFYUI_DIR/models"
export HF_HOME=/workspace/.cache/huggingface

# ---------------------------------------
# Persistent Python environment
# ---------------------------------------

export VENV_DIR=/workspace/h3-venv

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating persistent Python environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

mkdir -p "$HF_HOME"

# ---------------------------------------
# Check PyTorch CUDA version
# ---------------------------------------

echo "Checking PyTorch CUDA version..."

TORCH_CUDA=$(python - <<'PY'
try:
    import torch
    print(torch.version.cuda or "")
except Exception:
    print("")
PY
)

if [ "$TORCH_CUDA" != "13.0" ]; then
    echo "Current PyTorch CUDA version: ${TORCH_CUDA:-not installed}"
    echo "Installing PyTorch with CUDA 13.0 support..."

    pip uninstall -y torch torchvision torchaudio || true

    pip install \
        torch \
        torchvision \
        torchaudio \
        --index-url https://download.pytorch.org/whl/cu130

    echo "Verifying PyTorch..."

    python - <<'PY'
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
    echo "✓ PyTorch already uses CUDA 13.0"
fi

# ---------------------------------------
# Install ComfyUI if missing
# ---------------------------------------

COMFY_NEW_INSTALL=false

if [ ! -d "$COMFYUI_DIR/.git" ]; then
    echo "Installing ComfyUI..."

    git clone \
        https://github.com/comfyanonymous/ComfyUI.git \
        "$COMFYUI_DIR"

    COMFY_NEW_INSTALL=true
else
    echo "✓ ComfyUI already installed."
fi

cd "$COMFYUI_DIR"

# ---------------------------------------
# Install ComfyUI requirements
# Only on first ComfyUI install
# ---------------------------------------

if [ "$COMFY_NEW_INSTALL" = true ]; then
    echo "Installing ComfyUI requirements..."
    pip install -r requirements.txt
else
    echo "✓ Skipping ComfyUI requirements."
fi

# ---------------------------------------
# Install Hugging Face tools if missing
# ---------------------------------------

if ! command -v hf >/dev/null 2>&1 || \
   ! python -c "import hf_xet" >/dev/null 2>&1; then

    echo "Installing Hugging Face tools..."
    pip install -U huggingface_hub hf_xet
else
    echo "✓ Hugging Face tools already installed."
fi

# ---------------------------------------
# Re-check PyTorch
# ---------------------------------------

TORCH_CUDA=$(python - <<'PY'
import torch
print(torch.version.cuda or "")
PY
)

if [ "$TORCH_CUDA" != "13.0" ]; then
    echo "ComfyUI requirements changed PyTorch."
    echo "Reinstalling CUDA 13.0 PyTorch..."

    pip install --upgrade --force-reinstall \
        torch \
        torchvision \
        torchaudio \
        --index-url https://download.pytorch.org/whl/cu130
fi

# ---------------------------------------
# Create persistent folders
# ---------------------------------------

mkdir -p \
    "$MODELS_DIR/diffusion_models" \
    "$MODELS_DIR/text_encoders" \
    "$MODELS_DIR/vae" \
    "$MODELS_DIR/loras" \
    "$COMFYUI_DIR/input" \
    "$COMFYUI_DIR/output"

# ---------------------------------------
# Download helper
# ---------------------------------------

download_if_missing() {
    repo="$1"
    remote_file="$2"
    local_file="$3"
    minimum_bytes="$4"
    download_dir="$5"

    if [ -f "$local_file" ]; then
        actual_bytes=$(stat -c%s "$local_file")

        if [ "$actual_bytes" -ge "$minimum_bytes" ]; then
            echo "✓ Already downloaded:"
            echo "  $local_file"
            return
        fi

        echo "⚠ File exists but appears incomplete:"
        echo "  $local_file"
        echo "Removing incomplete file..."

        rm -f "$local_file"
    fi

    echo "↓ Downloading:"
    echo "  $remote_file"

    hf download \
        "$repo" \
        "$remote_file" \
        --local-dir "$download_dir"

    if [ ! -f "$local_file" ]; then
        echo "ERROR: Download completed but expected file was not found:"
        echo "  $local_file"
        exit 1
    fi

    actual_bytes=$(stat -c%s "$local_file")

    if [ "$actual_bytes" -lt "$minimum_bytes" ]; then
        echo "ERROR: Downloaded file is smaller than expected."
        echo "File: $local_file"
        echo "Expected at least: $minimum_bytes bytes"
        echo "Found: $actual_bytes bytes"
        exit 1
    fi

    echo "✓ Download complete:"
    echo "  $local_file"
}

# ---------------------------------------
# MiniMax H3 files
# ---------------------------------------

REPO="Comfy-Org/MiniMax-H3"

# Pruned H3 FL2VA INT8
# ~21 GB
download_if_missing \
    "$REPO" \
    "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
    "$MODELS_DIR/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
    20000000000 \
    "$MODELS_DIR"

# Qwen3-VL NVFP4 AWQ text encoder
# ~15.7 GB
download_if_missing \
    "$REPO" \
    "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
    "$MODELS_DIR/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
    15000000000 \
    "$MODELS_DIR"

# Video VAE
# ~5.21 GB
download_if_missing \
    "$REPO" \
    "vae/minimax_h3_video_vae_fp16.safetensors" \
    "$MODELS_DIR/vae/minimax_h3_video_vae_fp16.safetensors" \
    5200000000 \
    "$MODELS_DIR"

# Audio VAE
# ~605 MB
download_if_missing \
    "$REPO" \
    "vae/minimax_h3_audio_vae_fp32.safetensors" \
    "$MODELS_DIR/vae/minimax_h3_audio_vae_fp32.safetensors" \
    600000000 \
    "$MODELS_DIR"

# ---------------------------------------
# Turbo 8-step LoRA
# ---------------------------------------

download_if_missing \
    "lightx2v/Minimax-h3-Turbo" \
    "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
    "$MODELS_DIR/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
    1900000000 \
    "$MODELS_DIR/loras"

# ---------------------------------------
# Final environment check
# ---------------------------------------

echo
echo "Final environment:"

python - <<'PY'
import torch

print("PyTorch:", torch.__version__)
print("CUDA used by PyTorch:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(0))
print(
    "VRAM:",
    round(torch.cuda.get_device_properties(0).total_memory / 1024**3, 1),
    "GB"
)
PY

# ---------------------------------------
# Storage check
# ---------------------------------------

echo
echo "Workspace usage:"
du -sh /workspace

echo
echo "Model usage:"
du -sh "$MODELS_DIR"/* 2>/dev/null || true

# ---------------------------------------
# Start ComfyUI
# ---------------------------------------

echo
echo "======================================"
echo " MiniMax H3 setup complete"
echo " Starting ComfyUI on port 8188"
echo "======================================"
echo

exec python main.py \
    --listen 0.0.0.0 \
    --port 8188
