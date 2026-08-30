cd /workspace

cat > setup-h3.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export COMFYUI_DIR=/workspace/ComfyUI
export MODELS_DIR="$COMFYUI_DIR/models"
export HF_HOME=/workspace/.cache/huggingface

mkdir -p "$HF_HOME"

if [ ! -d "$COMFYUI_DIR/.git" ]; then
    echo "Installing ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
else
    echo "ComfyUI already installed."
fi

cd "$COMFYUI_DIR"

echo "Installing ComfyUI requirements..."
pip install -r requirements.txt

echo "Installing Hugging Face tools..."
pip install -U huggingface_hub hf_xet

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

echo "Starting ComfyUI..."

exec python main.py \
    --listen 0.0.0.0 \
    --port 8188
EOF
