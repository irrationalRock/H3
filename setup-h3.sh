#!/usr/bin/env bash
set -euo pipefail

export COMFYUI_DIR=/workspace/ComfyUI
export MODELS_DIR="$COMFYUI_DIR/models"
export HF_HOME=/workspace/.cache/huggingface

mkdir -p "$HF_HOME"

# ---------------------------------------
# Install ComfyUI if it isn't installed
# ---------------------------------------

if [ ! -d "$COMFYUI_DIR/.git" ]; then
    echo "Installing ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
else
    echo "✓ ComfyUI already installed."
fi

cd "$COMFYUI_DIR"

# ---------------------------------------
# Install Python dependencies
# ---------------------------------------

echo "Installing ComfyUI requirements..."
pip install -r requirements.txt

echo "Installing Hugging Face tools..."
pip install -U huggingface_hub hf_xet

# ---------------------------------------
# Create persistent directories
# ---------------------------------------

mkdir -p \
    "$MODELS_DIR/diffusion_models" \
    "$MODELS_DIR/text_encoders" \
    "$MODELS_DIR/vae" \
    "$MODELS_DIR/loras" \
    "$COMFYUI_DIR/input" \
    "$COMFYUI_DIR/output"

# ---------------------------------------
# Function: download only when necessary
# ---------------------------------------

download_if_missing() {
    repo="$1"
    remote_file="$2"
    local_file="$3"
    minimum_bytes="$4"

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
        --local-dir "$(dirname "$local_file")"

    if [ ! -f "$local_file" ]; then
        echo "ERROR: Download finished but expected file was not found:"
        echo "$local_file"
        exit 1
    fi

    actual_bytes=$(stat -c%s "$local_file")

    if [ "$actual_bytes" -lt "$minimum_bytes" ]; then
        echo "ERROR: Downloaded file is too small."
        echo "File: $local_file"
        echo "Expected at least: $minimum_bytes bytes"
        echo "Found: $actual_bytes bytes"
        exit 1
    fi

    echo "✓ Download completed:"
    echo "  $local_file"
}

# ---------------------------------------
# MiniMax H3 model downloads
# ---------------------------------------

REPO="Comfy-Org/MiniMax-H3"

# Pruned H3 FL2VA INT8 diffusion model
download_if_missing \
    "$REPO" \
    "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
    "$MODELS_DIR/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
    20000000000

# Qwen3-VL NVFP4 AWQ text encoder
download_if_missing \
    "$REPO" \
    "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
    "$MODELS_DIR/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
    15000000000

# Video VAE
download_if_missing \
    "$REPO" \
    "vae/minimax_h3_video_vae_fp16.safetensors" \
    "$MODELS_DIR/vae/minimax_h3_video_vae_fp16.safetensors" \
    5200000000

# Audio VAE
download_if_missing \
    "$REPO" \
    "vae/minimax_h3_audio_vae_fp32.safetensors" \
    "$MODELS_DIR/vae/minimax_h3_audio_vae_fp32.safetensors" \
    600000000

# Turbo 8-step LoRA
download_if_missing \
    "lightx2v/Minimax-h3-Turbo" \
    "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
    "$MODELS_DIR/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
    1900000000

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
