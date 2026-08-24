FROM nvidia/cuda:13.0.2-cudnn-runtime-ubuntu24.04

ARG COMFYUI_COMMIT=5ab2f7a2d676c1fb7b410c22e82e2ed8f217b56c
ARG SVDQUANT_COMMIT=56adad3ae84085039d0397da2d289f51e39b1c76

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends git python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/venv

WORKDIR /opt
RUN git clone https://github.com/comfyanonymous/ComfyUI.git \
    && git -C ComfyUI checkout "$COMFYUI_COMMIT" \
    && git clone https://github.com/alperktt/Krea-2-SVDQuant-ComfyUI.git \
      ComfyUI/custom_nodes/krea-2-svdquant \
    && git -C ComfyUI/custom_nodes/krea-2-svdquant checkout "$SVDQUANT_COMMIT" \
    && rm -rf ComfyUI/.git ComfyUI/custom_nodes/krea-2-svdquant/.git

RUN python -m pip install --upgrade pip \
    && python -m pip install \
      torch==2.11.0+cu130 torchvision==0.26.0+cu130 torchaudio==2.11.0+cu130 \
      --index-url https://download.pytorch.org/whl/cu130 \
    && python -m pip install -r /opt/ComfyUI/requirements.txt

WORKDIR /opt/ComfyUI
EXPOSE 8188

HEALTHCHECK --interval=5s --timeout=3s --start-period=30s --retries=24 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8188/system_stats', timeout=2)" || exit 1

ENTRYPOINT ["python", "main.py"]
CMD ["--listen", "0.0.0.0", "--port", "8188", "--reserve-vram", "1", "--disable-all-custom-nodes", "--whitelist-custom-nodes", "krea-2-svdquant"]
