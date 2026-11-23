cd C:\Users\rajee\RAFNet
$content = @'
# RAFNet backend - full real-inference image (Render web service).
#
# RAM: torch CPU + WavLM-base-plus (~94M params, ~360 MB fp32) peaks well
# above the 512 MB free tier. Use >= 1 GB RAM; 2 GB+ recommended.
FROM python:3.12-slim

# Render injects $PORT (10000 by default). No secrets are baked into this
# image: Supabase keys and the CORS allow-list are supplied at runtime.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=10000 \
    MOCK_INFERENCE=false \
    RAFNET_DEVICE=cpu \
    RAFNET_ENV=production \
    SOC_REQUIRE_AUTH=true \
    HF_HOME=/opt/hf-cache \
    HF_HUB_OFFLINE=0

WORKDIR /app

# 1. PyTorch CPU first (separate index - PyPI wheels would pull CUDA builds).
RUN pip install --no-cache-dir torch torchaudio --index-url https://download.pytorch.org/whl/cpu

# 2. Full ML runtime (scikit-learn==1.9.1 matches the training pickles).
COPY requirements-ml.txt ./
RUN pip install --no-cache-dir -r requirements-ml.txt

# 3. Application plus the small, tracked config/checkpoint files.
COPY src ./src
COPY experiments ./experiments
COPY supabase ./supabase
COPY configs ./configs
COPY models/stacking.json ./models/stacking.json
COPY models/head_phase4.pt ./models/head_phase4.pt

# 4. Bake WavLM into a SHARED cache (not root's HOME) so the non-root runtime
#    never needs to download it on first boot.
RUN python -c "from transformers import WavLMModel; WavLMModel.from_pretrained('microsoft/wavlm-base-plus')"

# 5. Bake the two anti-spoof models used on the first analysis (optional:
#    delete this step if the build fails here; they then download at runtime).
RUN python -c "from transformers import AutoModelForAudioClassification as M; M.from_pretrained('mo-thecreator/Deepfake-audio-detection'); M.from_pretrained('Bisher/wav2vec2_ASV_deepfake_audio_detection')"

# 6. Non-root runtime user owns the app and the model cache.
RUN useradd --create-home --shell /bin/sh rafnet \
    && chown -R rafnet:rafnet /app /opt/hf-cache

USER rafnet
WORKDIR /app/src

EXPOSE 10000
CMD ["sh", "-c", "exec uvicorn rafnet.api.main:app --host 0.0.0.0 --port \"${PORT:-10000}\""]
'@
[System.IO.File]::WriteAllText("$PWD\Dockerfile", $content, (New-Object System.Text.UTF8Encoding($false)))
Get-Content Dockerfile | Select-Object -First 8