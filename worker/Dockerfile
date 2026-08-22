# syntax=docker/dockerfile:1.7
# The digest pins the official CUDA 12.8 ComfyUI Pod image used by the spike.
ARG COMFYUI_IMAGE=runpod/comfyui@sha256:dda6f948c7c3087244e15fbe0265b0e13b55df02bb0b3d66049f95858b284b37
FROM ${COMFYUI_IMAGE}

ARG KREA_REVISION=main
ARG KREA_BASE_URL=https://huggingface.co/Comfy-Org/Krea-2/resolve

USER root

RUN mkdir -p \
      /opt/flujo-models/diffusion_models \
      /opt/flujo-models/text_encoders \
      /opt/flujo-models/vae && \
    curl --fail --location --retry 5 --retry-all-errors \
      "${KREA_BASE_URL}/${KREA_REVISION}/diffusion_models/krea2_turbo_fp8_scaled.safetensors?download=true" \
      --output /opt/flujo-models/diffusion_models/krea2_turbo_fp8_scaled.safetensors && \
    echo "eb4dd8c612cfd10f64f25b057e6e6bbcb5737c94a7372177e456dbf7579502f1  /opt/flujo-models/diffusion_models/krea2_turbo_fp8_scaled.safetensors" | sha256sum --check - && \
    curl --fail --location --retry 5 --retry-all-errors \
      "${KREA_BASE_URL}/${KREA_REVISION}/text_encoders/qwen3vl_4b_fp8_scaled.safetensors?download=true" \
      --output /opt/flujo-models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors && \
    echo "54bd5144df0bbc25dd6ccadfcb826b521445a1b06ae5a42570bdd2974ca87094  /opt/flujo-models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors" | sha256sum --check - && \
    curl --fail --location --retry 5 --retry-all-errors \
      "${KREA_BASE_URL}/${KREA_REVISION}/vae/qwen_image_vae.safetensors?download=true" \
      --output /opt/flujo-models/vae/qwen_image_vae.safetensors && \
    echo "a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f  /opt/flujo-models/vae/qwen_image_vae.safetensors" | sha256sum --check - && \
    mkdir -p /opt/comfyui-baked/models/diffusion_models \
      /opt/comfyui-baked/models/text_encoders \
      /opt/comfyui-baked/models/vae && \
    ln -s /opt/flujo-models/diffusion_models/krea2_turbo_fp8_scaled.safetensors \
      /opt/comfyui-baked/models/diffusion_models/krea2_turbo_fp8_scaled.safetensors && \
    ln -s /opt/flujo-models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors \
      /opt/comfyui-baked/models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors && \
    ln -s /opt/flujo-models/vae/qwen_image_vae.safetensors \
      /opt/comfyui-baked/models/vae/qwen_image_vae.safetensors

# Preserve the base image's entrypoint and install a mount-safe shim at the
# original path. RunPod mounts /workspace before this script runs.
RUN mv /start.sh /start-runpod.sh
COPY start.sh /start.sh
RUN chmod 0755 /start.sh /start-runpod.sh

LABEL org.opencontainers.image.title="Flujo Krea 2 Turbo ComfyUI worker" \
      org.opencontainers.image.source="https://github.com/huytd2k/flujo" \
      ai.flujo.model="Comfy-Org/Krea-2:krea2_turbo_fp8_scaled"

HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=12 \
  CMD curl --fail --silent http://127.0.0.1:8188/system_stats >/dev/null || exit 1
