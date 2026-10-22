#!/bin/bash
# Sets up the dev mode's heavier tools on the GPU host, each in its own
# Python beside the server's (which stays on onnxruntime alone):
#   align   - re-times Whisper's words by CTC forced alignment with
#             ReazonSpeech's Japanese wav2vec2 (Apache-2.0), PyTorch.
#   diarize - tells the speakers apart with DiariZen (code MIT, weights
#             CC BY-NC 4.0: personal, non-commercial use), Python 3.10
#             and torch 2.1.1 as it is pinned to.
#   hear_nemo, hear_qwen, hear_vibevoice - hear each caption again with
#             ReazonSpeech nemo-v2 (Apache-2.0), Qwen3-ASR-1.7B (Apache-2.0)
#             and VibeVoice-ASR (MIT, about 17 GB of GPU memory), to set
#             beside the captions' own recognizer.
# Usage: setup.sh [DIR], DIR defaulting to ~/livetrans/devtools. Needs uv
# and git; the models download from Hugging Face on first use.
set -euo pipefail
DIR="${1:-$HOME/livetrans/devtools}"
mkdir -p "$DIR"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ ! -x align/bin/python ]; then
    uv venv --python 3.12 align
    uv pip install --python align/bin/python torch==2.14.1 transformers==5.19.0 tokenizers==0.23.3 pykakasi==2.3.0 numpy
fi

if [ ! -d DiariZen ]; then
    git clone https://github.com/BUTSpeechFIT/DiariZen.git
    git -C DiariZen checkout 844f5555b0a98acd0931511fc641a8c5b8ba92c7
fi
if [ ! -x diarize/bin/python ]; then
    uv venv --python 3.10 diarize
    # The versions DiariZen was run with on this host, torch 2.1.1 for CUDA 12.1.
    uv pip install --python diarize/bin/python --index-strategy unsafe-best-match \
        --extra-index-url https://download.pytorch.org/whl/cu121 -r "$HERE/diarize-requirements.txt"
    uv pip install --python diarize/bin/python --no-deps -e DiariZen/pyannote-audio -e DiariZen
fi
if [ ! -x hear_nemo/bin/python ]; then
    uv venv --python 3.12 hear_nemo
    uv pip install --python hear_nemo/bin/python torch==2.14.1 "nemo-toolkit[asr]==3.0.0"
fi
if [ ! -x hear_qwen/bin/python ]; then
    uv venv --python 3.12 hear_qwen
    uv pip install --python hear_qwen/bin/python torch==2.14.1 qwen-asr==0.0.6
fi
if [ ! -x hear_vibevoice/bin/python ]; then
    uv venv --python 3.12 hear_vibevoice
    uv pip install --python hear_vibevoice/bin/python torch==2.14.1 transformers==5.20.0 accelerate==1.15.0 librosa==1.0.0
fi
# The workers the server runs in these Pythons.
cp "$HERE/align.py" "$HERE/diarize.py" "$HERE/hear_nemo.py" "$HERE/hear_qwen.py" "$HERE/hear_vibevoice.py" "$DIR/"
echo "dev tools ready in $DIR"
