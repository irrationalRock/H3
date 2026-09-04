#!/usr/bin/env bash
set -euo pipefail

export COMFYUI_DIR=/workspace/ComfyUI
export MODELS_DIR="$COMFYUI_DIR/models"
export HF_HOME=/workspace/.cache/huggingface

# Persistent Python environment
export VENV_DIR=/workspace/h3-venv

mkdir -p "$HF_HOME"

# Create persistent venv only once
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating persistent Python environment..."
    python3 -m venv "$VENV_DIR"
fi

# Always use the persistent environment
source "$VENV_DIR/bin/activate"

echo "Using Python:"
which python
python --version

# Upgrade pip inside persistent environment
python -m pip install -U pip

# Install CUDA 13.0 PyTorch only if needed
if ! python -c "import torch; exit(0 if torch.version.cuda == '13.0' else 1)" 2>/dev/null; then
    echo "Installing PyTorch with CUDA 13.0..."

    python -m pip install -U \
        torch \
        torchvision \
        torchaudio \
        --index-url https://download.pytorch.org/whl/cu130
else
    echo "CUDA 13.0 PyTorch already installed."
fi

if [ ! -d "$COMFYUI_DIR/.git" ]; then
    echo "Installing ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
else
    echo "ComfyUI already installed."
fi

cd "$COMFYUI_DIR"

echo "Installing ComfyUI requirements..."
python -m pip install -r requirements.txt

echo "Installing Hugging Face tools..."
python -m pip install -U huggingface_hub hf_xet

mkdir -p \
    "$MODELS_DIR/diffusion_models" \
    "$MODELS_DIR/text_encoders" \
    "$MODELS_DIR/vae" \
    "$COMFYUI_DIR/input" \
    "$COMFYUI_DIR/output"

download_if_missing() {
    repo="$1"
    remote_file="$2"
    local_file="$3"
    minimum_bytes="$4"

    if [ -f "$local_file" ]; then
        actual_bytes=$(stat -c%s "$local_file")

        if [ "$actual_bytes" -ge "$minimum_bytes" ]; then
            echo "Already downloaded: $local_file"
            return
        fi

        echo "Incomplete file found, removing it:"
        echo "$local_file"
        rm -f "$local_file"
    fi

    echo "Downloading: $remote_file"

    hf download \
        "$repo" \
        "$remote_file" \
        --local-dir "$MODELS_DIR"

    if [ ! -f "$local_file" ]; then
        echo "ERROR: Expected file was not created:"
        echo "$local_file"
        exit 1
    fi

    actual_bytes=$(stat -c%s "$local_file")

    if [ "$actual_bytes" -lt "$minimum_bytes" ]; then
        echo "ERROR: Download appears incomplete:"
        echo "$local_file"
        exit 1
    fi

    echo "Download complete: $local_file"
}

REPO="Comfy-Org/MiniMax-H3"

download_if_missing \
    "$REPO" \
    "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" \
    "$MODELS_DIR/diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" \
    33000000000

download_if_missing \
    "$REPO" \
    "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" \
    "$MODELS_DIR/text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" \
    26000000000

download_if_missing \
    "$REPO" \
    "vae/minimax_h3_video_vae_fp16.safetensors" \
    "$MODELS_DIR/vae/minimax_h3_video_vae_fp16.safetensors" \
    5200000000

download_if_missing \
    "$REPO" \
    "vae/minimax_h3_audio_vae_fp32.safetensors" \
    "$MODELS_DIR/vae/minimax_h3_audio_vae_fp32.safetensors" \
    600000000

echo "--------------------------------"
echo "PyTorch version:"
python -c "import torch; print(torch.__version__)"

echo "PyTorch CUDA build:"
python -c "import torch; print(torch.version.cuda)"

echo "GPU:"
python -c "import torch; print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CUDA unavailable')"
echo "--------------------------------"

echo "Starting ComfyUI..."

exec python main.py \
    --listen 0.0.0.0 \
    --port 8188
