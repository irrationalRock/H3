#!/usr/bin/env bash
# Install native ComfyUI + official MOSS-SFT workflow on an NVIDIA RunPod Pod.
# Use a current Python 3.11/3.12 CUDA image; expose HTTP port 8188.
# Mount persistent storage at /workspace. No prior Gradio setup is needed.
# bash setup_moss_comfyui_runpod.sh
# START_UI=0 bash setup_moss_comfyui_runpod.sh   # install only
# UPDATE_COMFY=1 bash setup_moss_comfyui_runpod.sh # explicit fast-forward update
# Restart: bash /workspace/moss-comfy/start.sh
# Lower VRAM: bash /workspace/moss-comfy/start.sh --lowvram
set -Eeuo pipefail
trap 'printf "\nSetup failed at line %s. Read the error above, fix it, and rerun.\n" "$LINENO" >&2' ERR
ROOT="${MOSS_COMFY_ROOT:-/workspace/moss-comfy}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
for cmd in git "$PYTHON_BIN" nvidia-smi; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd; use a Python/CUDA GPU Pod with git installed." >&2; exit 1; }
done
nvidia-smi
"$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3,10), "Python 3.10+ required; 3.11/3.12 recommended"'
mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd)"
export ROOT
export HF_HOME="$ROOT/cache/huggingface"
export PIP_CACHE_DIR="$ROOT/cache/pip"
export TMPDIR="$ROOT/tmp"
mkdir -p "$HF_HOME" "$PIP_CACHE_DIR" "$TMPDIR" "$ROOT/workflows"
COMFY="$ROOT/ComfyUI"
export COMFY
if [[ ! -e "$COMFY" ]]; then
  git clone --depth 1 --branch master https://github.com/Comfy-Org/ComfyUI.git "$COMFY"
elif [[ ! -d "$COMFY/.git" ]]; then
  echo "$COMFY exists but is not a Git checkout; use a new MOSS_COMFY_ROOT." >&2
  exit 1
elif [[ "${UPDATE_COMFY:-0}" == 1 ]]; then
  [[ -z "$(git -C "$COMFY" status --porcelain)" ]] || { echo 'ComfyUI has local changes; update manually.' >&2; exit 1; }
  git -C "$COMFY" pull --ff-only
fi
# Fail early for a checkout predating native MOSS support.
"$PYTHON_BIN" - <<'PY'
import os
from pathlib import Path
p=Path(os.environ['COMFY'])/'nodes.py'
if 'moss_image' not in p.read_text():
    raise SystemExit('This ComfyUI checkout lacks native MOSS. Rerun with UPDATE_COMFY=1.')
PY
if [[ ! -x "$ROOT/venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$ROOT/venv" || {
    echo 'Install python3-venv for your Python version, then rerun.' >&2; exit 1;
  }
fi
PY="$ROOT/venv/bin/python"
"$PY" -m pip install --upgrade pip setuptools wheel
# Optional override for an image that requires a specific CUDA wheel index.
if [[ -n "${TORCH_INDEX_URL:-}" ]]; then
  "$PY" -m pip install torch torchvision --index-url "$TORCH_INDEX_URL"
fi
"$PY" -m pip install -r "$COMFY/requirements.txt" huggingface_hub
"$PY" -m pip check
"$PY" - <<'PY'
import torch
if not torch.cuda.is_available():
    raise SystemExit('PyTorch cannot access CUDA. Check your GPU Pod image/driver and torch build.')
x=torch.ones(1,device='cuda')
print('CUDA ready:',torch.cuda.get_device_name(0),'| torch',torch.__version__)
PY

# Fetch the official native workflow, validate its model references, then
# download directly into ComfyUI/models without keeping duplicate weight copies.
"$PY" - <<'PY'
import json, os, shutil, urllib.request
from pathlib import Path
from urllib.parse import urlparse, unquote
from huggingface_hub import HfApi, hf_hub_download
root=Path(os.environ['ROOT']); comfy=Path(os.environ['COMFY'])
workflow=root/'workflows'/'MOSS-SFT-official.json'
url='https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_moss_image_t2i.json'
# Preserve the downloaded template on reruns for consistency.
if workflow.exists():
    data=json.loads(workflow.read_text())
else:
    with urllib.request.urlopen(url, timeout=90) as r:
        data=json.load(r)
if not isinstance(data.get('nodes'),list):
    raise SystemExit('Downloaded workflow is not a ComfyUI UI workflow.')
models=set()
def walk(x):
    if isinstance(x,dict):
        for m in x.get('models',[]):
            if not isinstance(m,dict) or 'url' not in m: continue
            u=urlparse(m['url']); prefix='/Comfy-Org/MOSS-Image/resolve/main/'
            if u.scheme!='https' or u.netloc!='huggingface.co' or not u.path.startswith(prefix):
                raise SystemExit('Unexpected model source in workflow: inspect the official template.')
            name=unquote(u.path[len(prefix):])
            parts=name.split('/')
            if len(parts)!=2 or parts[0] not in ('diffusion_models','text_encoders','vae') or not parts[1].endswith('.safetensors'):
                raise SystemExit('Unexpected model filename: '+name)
            models.add(name)
        for v in x.values(): walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(data)
if {p.split('/')[0] for p in models}!={'diffusion_models','text_encoders','vae'}:
    raise SystemExit('Workflow does not specify all three required model components.')
model_root=comfy/'models'; model_root.mkdir(exist_ok=True)
info=HfApi().model_info('Comfy-Org/MOSS-Image',files_metadata=True)
sizes={s.rfilename:s.size for s in info.siblings}
needed=sum(sizes.get(p) or 0 for p in models if not (model_root/p).exists())
free=shutil.disk_usage(model_root).free
print(f'Model download estimate: {needed/1e9:.1f} GB; free disk: {free/1e9:.1f} GB',flush=True)
if free < needed+5*1024**3:
    raise SystemExit('Insufficient free disk for models plus 5 GiB output headroom. Expand your volume.')
for name in sorted(models):
    print('Downloading '+name,flush=True)
    hf_hub_download('Comfy-Org/MOSS-Image',filename=name,revision=info.sha,local_dir=str(model_root))
workflow.write_text(json.dumps(data,indent=2)+'\n')
user_dir=comfy/'user'/'default'/'workflows'; user_dir.mkdir(parents=True,exist_ok=True)
dest=user_dir/workflow.name
if not dest.exists(): shutil.copyfile(workflow,dest)
(root/'model-revision.txt').write_text(info.sha+'\n')
print('Workflow saved:',workflow)
PY

git -C "$COMFY" rev-parse HEAD > "$ROOT/comfyui-commit.txt"
"$PY" -m pip freeze > "$ROOT/installed-packages.txt"
cat > "$ROOT/start.sh" <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export HF_HOME="$ROOT/cache/huggingface"
export TMPDIR="$ROOT/tmp"
mkdir -p "$TMPDIR"
cd "$ROOT/ComfyUI"
echo "Open RunPod Connect -> HTTP service ${PORT:-8188} after startup."
echo "Workflow: $ROOT/workflows/MOSS-SFT-official.json"
echo "Images: $ROOT/ComfyUI/output"
exec "$ROOT/venv/bin/python" main.py --listen "${HOST:-0.0.0.0}" --port "${PORT:-8188}" --fp32-vae "$@"
START
chmod +x "$ROOT/start.sh"
echo "Setup complete. Restart: bash $ROOT/start.sh"
echo 'Open the MOSS-SFT-official workflow, enter a prompt, then click Run.'
if [[ "${START_UI:-1}" == 1 ]]; then exec bash "$ROOT/start.sh"; fi
