# Flujo Krea 2 Pod image

This is a regular RunPod Pod image, not a Serverless worker. It extends the
official RunPod ComfyUI image and contains the exact model bundle tested by
Flujo:

- `krea2_turbo_fp8_scaled.safetensors`
- `qwen3vl_4b_fp8_scaled.safetensors`
- `qwen_image_vae.safetensors`

The files live under `/opt/flujo-models`. At boot, `start.sh` links them into
ComfyUI's `/workspace/runpod-slim/ComfyUI/models` tree. A RunPod volume mounted
at `/workspace` therefore does not hide the baked model layers.

## Build and publish

The final image is roughly the RunPod base image plus 18.6 GB of model data.
Build on an amd64 machine with at least 40 GB free, or use the included GitHub
Actions workflow.

```sh
docker buildx build \
  --platform linux/amd64 \
  --file worker/Dockerfile \
  --tag ghcr.io/huytd2k/flujo-krea2:v0.1 \
  --push \
  worker
```

The build downloads each model once and checks its Hugging Face LFS SHA-256.
Do not use an unverified parallel range downloader for these files.

## Create the RunPod template

The image must be public, or the RunPod template must be associated with a
container registry credential. Then run:

```sh
RUNPOD_API_KEY='temporary-key' \
  worker/create-runpod-template.sh ghcr.io/huytd2k/flujo-krea2:v0.1
```

The template is private, uses normal Pods (`isServerless: false`), exposes
ComfyUI on `8188/http`, and keeps the stock RunPod entrypoint.

For the tested FP8 workflow, choose a 24 GB GPU such as an RTX 3090 or RTX
4090. The RTX 5090 needs RunPod's CUDA 13 ComfyUI base variant instead of this
CUDA 12.8 image.

