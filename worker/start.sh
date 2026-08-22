#!/usr/bin/env bash
set -euo pipefail

readonly COMFY_MODELS=/workspace/runpod-slim/ComfyUI/models
readonly BAKED_MODELS=/opt/flujo-models

link_model() {
  local kind="$1"
  local filename="$2"
  mkdir -p "${COMFY_MODELS}/${kind}"
  ln -sfn "${BAKED_MODELS}/${kind}/${filename}" "${COMFY_MODELS}/${kind}/${filename}"
}

# On a fresh volume, the stock entrypoint copies /opt/comfyui-baked (which
# already contains these links). On an existing volume, refresh them here.
# Do not create COMFY_MODELS before the stock first-time setup: doing so would
# make it mistake the otherwise-empty directory for an installed ComfyUI tree.
if [[ -d /workspace/runpod-slim/ComfyUI ]]; then
  link_model diffusion_models krea2_turbo_fp8_scaled.safetensors
  link_model text_encoders qwen3vl_4b_fp8_scaled.safetensors
  link_model vae qwen_image_vae.safetensors
fi

echo "Flujo: Krea 2 Turbo models linked from the baked image layer"
exec /start-runpod.sh "$@"
