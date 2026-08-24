#!/usr/bin/env bash
set -euo pipefail

readonly COMFY_ROOT="${FLUJO_COMFYUI_DIR:-/home/huytran/ComfyUI}"
readonly COMFY_PYTHON="${FLUJO_COMFY_PYTHON:-/home/huytran/micromamba/envs/comfyenv/bin/python3.11}"
readonly MODEL_PATHS="${FLUJO_COMFY_MODEL_PATHS:-/home/huytran/sources/flujo/spike/krea2_svdquant_extra_models.yaml}"
readonly GPU="${FLUJO_CUDA_DEVICE:-0}"
readonly LISTEN_ADDRESS="${FLUJO_COMFY_LISTEN:-192.168.0.33}"
readonly FLUJO_ORIGIN="${FLUJO_PHONE_ORIGIN:-http://192.168.0.33:8080}"

if [[ ! -x "$COMFY_PYTHON" ]]; then
  echo "Flujo ComfyUI Python is not executable: $COMFY_PYTHON" >&2
  exit 1
fi

if [[ ! -f "$COMFY_ROOT/main.py" ]]; then
  echo "ComfyUI main.py was not found under: $COMFY_ROOT" >&2
  exit 1
fi

if [[ ! -f "$MODEL_PATHS" ]]; then
  echo "Extra model paths file was not found: $MODEL_PATHS" >&2
  exit 1
fi

"$COMFY_PYTHON" - <<'PY'
import sys
import torch

cuda = torch.version.cuda or "0"
major = int(cuda.split(".", 1)[0])
if major < 13:
    raise SystemExit(
        f"Flujo SVDQuant requires a cu130+ PyTorch build; found "
        f"torch {torch.__version__}, CUDA {cuda}"
    )
if not torch.cuda.is_available():
    raise SystemExit("PyTorch cannot access CUDA")
print(
    f"Flujo local worker: Python {sys.version.split()[0]}, "
    f"torch {torch.__version__}, CUDA {cuda}, GPU {torch.cuda.get_device_name(0)}"
)
PY

cd "$COMFY_ROOT"
exec env CUDA_VISIBLE_DEVICES="$GPU" "$COMFY_PYTHON" main.py \
  --listen "$LISTEN_ADDRESS" \
  --port 8188 \
  --enable-cors-header "$FLUJO_ORIGIN" \
  --reserve-vram 1 \
  --extra-model-paths-config "$MODEL_PATHS" \
  --disable-all-custom-nodes \
  --whitelist-custom-nodes krea-2-svdquant
