#!/usr/bin/env bash
#
# pi_bootstrap.sh — one-shot setup for the tau-bench smoke run on a fresh
# Prime Intellect pod (image: slimerl/slime:latest, 2x H100 80GB, 100GB
# persistent volume mounted at /data).
#
# Idempotent: safe to re-run if the pod restarts. Each step skips itself if
# the artifact it produces already exists on the persistent volume.
#
# Prerequisites (the operator exports these before invoking):
#   OPENAI_API_KEY  — used by tau-bench's gpt-4o-mini user simulator
#   WANDB_API_KEY   — used by slime training for wandb logging

set -euo pipefail

: "${OPENAI_API_KEY:?OPENAI_API_KEY must be exported before running this script}"
: "${WANDB_API_KEY:?WANDB_API_KEY must be exported before running this script}"

PERSIST=/data
if ! mountpoint -q "${PERSIST}" && [[ ! -d "${PERSIST}" ]]; then
  echo "ERROR: ${PERSIST} is neither a mountpoint nor an existing directory." >&2
  echo "       Provision a persistent volume mounted at ${PERSIST} before running." >&2
  exit 1
fi
mkdir -p "${PERSIST}/logs"

SLIME_DIR=/root/slime
TAU_DIR="${PERSIST}/tau-bench"
HF_DIR="${PERSIST}/Qwen3-4B-Instruct-2507"
MCORE_DIR="${PERSIST}/Qwen3-4B-Instruct-2507_torch_dist"

# 1. slime — clone if missing, then editable install (the image already
#    contains slime, but we re-install in editable mode so local edits stick).
if [[ ! -d "${SLIME_DIR}/.git" ]]; then
  echo "[bootstrap] cloning slime to ${SLIME_DIR}"
  git clone https://github.com/THUDM/slime.git "${SLIME_DIR}"
fi
( cd "${SLIME_DIR}" && pip install -e . --no-deps )

# 2. tau-bench fork (JD-ETH with LiteLLM retry support)
if [[ ! -d "${TAU_DIR}/.git" ]]; then
  echo "[bootstrap] cloning tau-bench fork to ${TAU_DIR}"
  git clone https://github.com/JD-ETH/tau-bench.git "${TAU_DIR}"
  ( cd "${TAU_DIR}" && git checkout feature/litellm-retry )
fi
( cd "${TAU_DIR}" && pip install -e . --no-deps )

# 3. HF model download
if [[ ! -f "${HF_DIR}/config.json" ]]; then
  echo "[bootstrap] downloading Qwen3-4B-Instruct-2507 to ${HF_DIR}"
  huggingface-cli download Qwen/Qwen3-4B-Instruct-2507 \
    --local-dir "${HF_DIR}" --local-dir-use-symlinks False
else
  echo "[bootstrap] HF checkpoint already present at ${HF_DIR}"
fi

# 4. mcore (torch_dist) conversion — only if not already converted
if [[ ! -d "${MCORE_DIR}" ]] || [[ -z "$(ls -A "${MCORE_DIR}" 2>/dev/null)" ]]; then
  echo "[bootstrap] converting HF checkpoint to mcore torch_dist format"
  # shellcheck source=/dev/null
  source "${SLIME_DIR}/scripts/models/qwen3-4B-Instruct-2507.sh"
  PYTHONPATH=/root/Megatron-LM python "${SLIME_DIR}/tools/convert_hf_to_torch_dist.py" \
    "${MODEL_ARGS[@]}" \
    --hf-checkpoint "${HF_DIR}" \
    --save "${MCORE_DIR}"
else
  echo "[bootstrap] mcore checkpoint already present at ${MCORE_DIR}"
fi

# 5. Mock tau-bench train/dev tasks — only if missing
if [[ ! -f "${TAU_DIR}/retail_train_tasks.jsonl" ]]; then
  echo "[bootstrap] generating tau-bench mock prompt files"
  ( cd "${SLIME_DIR}/examples/tau-bench" \
      && python tau1_mock.py --local_dir "${TAU_DIR}/" )
else
  echo "[bootstrap] tau-bench prompt files already present at ${TAU_DIR}"
fi

echo
echo "bootstrap complete; run scripts/pi_launch_train.sh next"
