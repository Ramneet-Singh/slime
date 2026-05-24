#!/usr/bin/env bash
#
# pi_launch_train.sh — start (or refuse to double-start) the tau-bench
# smoke training run inside tmux so the run survives SSH disconnects.
#
# Run on a Prime Intellect pod that has already been bootstrapped via
# scripts/pi_bootstrap.sh. The training launch is wrapped in tmux session
# "slime-tau"; reattach with `tmux a -t slime-tau`.

set -euo pipefail

: "${OPENAI_API_KEY:?OPENAI_API_KEY must be exported before running this script}"
: "${WANDB_API_KEY:?WANDB_API_KEY must be exported before running this script}"

SESSION=slime-tau
PERSIST=/data
SLIME_DIR=/root/slime
RUN_SCRIPT="${SLIME_DIR}/examples/tau-bench/run_qwen3_4B.sh"
LOG_DIR="${PERSIST}/logs"

if [[ ! -x "$(command -v tmux)" ]]; then
  echo "ERROR: tmux is not installed in this pod image." >&2
  exit 1
fi

# Verify bootstrap artifacts before launching
missing=0
for path in \
    "${PERSIST}/Qwen3-4B-Instruct-2507/config.json" \
    "${PERSIST}/Qwen3-4B-Instruct-2507_torch_dist" \
    "${PERSIST}/tau-bench/retail_train_tasks.jsonl" \
    "${PERSIST}/tau-bench/retail_dev_tasks.jsonl" \
    "${RUN_SCRIPT}"; do
  if [[ ! -e "${path}" ]]; then
    echo "ERROR: missing bootstrap artifact: ${path}" >&2
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  echo "Run scripts/pi_bootstrap.sh first." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/run-$(date +%Y%m%d-%H%M%S).log"

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  echo "tmux session '${SESSION}' is already running."
  echo "Reattach with: tmux a -t ${SESSION}"
  echo "(If you really want to start fresh: tmux kill-session -t ${SESSION})"
  exit 1
fi

# Pass through the keys the training run needs.
tmux new-session -d -s "${SESSION}" \
  "OPENAI_API_KEY='${OPENAI_API_KEY}' WANDB_API_KEY='${WANDB_API_KEY}' \
   bash '${RUN_SCRIPT}' 2>&1 | tee '${LOG_FILE}'"

echo "Started tmux session '${SESSION}'."
echo "  Reattach:   tmux a -t ${SESSION}"
echo "  Log file:   ${LOG_FILE}"
echo "  Wandb:      project=\${WANDB_PROJECT:-slime-tau-bench} group=qwen3-4B-pi-smoke"
