#!/usr/bin/env bash
#
# pi_bootstrap.sh — one-shot setup for the tau-bench smoke run on a fresh
# Prime Intellect pod (image: ramneetsingh/slime-ssh:latest, 2x H100 80GB).
#
# Writes everything (model downloads, mcore conversion, tau-bench fork,
# slime checkpoint, logs) under /workspace on the ephemeral root disk.
# If the pod restarts, all of this is lost and bootstrap must redo it.
# To make /workspace survive a restart, attach a persistent volume at
# /workspace before launching the pod (no script change needed).
#
# Idempotent: safe to re-run. Each step skips itself if its artifact is
# already present in /workspace.
#
# Prerequisites (the operator exports these before invoking):
#   OPENAI_API_KEY  — used by tau-bench's gpt-4o-mini user simulator
#   WANDB_API_KEY   — used by slime training for wandb logging

set -euo pipefail

: "${OPENAI_API_KEY:?OPENAI_API_KEY must be exported before running this script}"
: "${WANDB_API_KEY:?WANDB_API_KEY must be exported before running this script}"

PERSIST=/workspace
mkdir -p "${PERSIST}/logs"

SLIME_DIR=/root/slime
TAU_DIR="${PERSIST}/tau-bench"
HF_DIR="${PERSIST}/Qwen3-4B-Instruct-2507"
MCORE_DIR="${PERSIST}/Qwen3-4B-Instruct-2507_torch_dist"

# 1. slime — replace the in-image copy with this fork. The slimerl/slime
#    image ships an upstream snapshot at /root/slime that lacks our PI
#    smoke-run patches (paths, OpenAI user sim, wandb args, etc.), so we
#    blow it away and clone the fork. Re-install in editable mode.
SLIME_REPO="${SLIME_REPO:-https://github.com/Ramneet-Singh/slime.git}"
SLIME_BRANCH="${SLIME_BRANCH:-main}"
if [[ ! -d "${SLIME_DIR}/.git" ]] || \
   ! ( cd "${SLIME_DIR}" && git remote get-url origin 2>/dev/null | grep -qi 'Ramneet-Singh/slime' ); then
  echo "[bootstrap] (re)cloning ${SLIME_REPO} (branch ${SLIME_BRANCH}) to ${SLIME_DIR}"
  rm -rf "${SLIME_DIR}"
  git clone --branch "${SLIME_BRANCH}" "${SLIME_REPO}" "${SLIME_DIR}"
else
  echo "[bootstrap] ${SLIME_DIR} already points at Ramneet-Singh/slime; pulling latest ${SLIME_BRANCH}"
  ( cd "${SLIME_DIR}" && git fetch origin "${SLIME_BRANCH}" && git checkout "${SLIME_BRANCH}" && git pull --ff-only origin "${SLIME_BRANCH}" )
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
