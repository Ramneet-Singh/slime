# PI smoke-run runbook — `examples/tau-bench/run_qwen3_4B.sh`

Operator playbook for running the unmodified tau-bench example on a Prime
Intellect on-demand pod as a baseline validation of the slime + PI pipeline.

This is a **before-Harbor** baseline. Do not patch in Harbor changes against
this run; spin a separate branch for that work and compare its curves to the
ones produced here.

## Run parameters (resolved decisions)

| Knob | Value |
|---|---|
| GPUs | 1× H200 141GB, on-demand (single-GPU config; see § 1 for alternatives) |
| Pod image | `ramneetsingh/slime-ssh:latest` (thin SSH wrapper over `slimerl/slime:latest` — see § 1a) |
| Working dir | `/workspace` on the **ephemeral root disk** (no persistent volume) |
| User simulator | OpenAI `gpt-4o-mini` via LiteLLM |
| `--num-rollout` | 50 |
| `--save-interval` | 50 (only the final checkpoint is written) |
| Dynamic sampling filter | `check_reward_nonzero_std` (as-shipped; inflates OpenAI cost 2-3×) |
| Monitoring | wandb project `slime-tau-bench`, group `qwen3-4B-pi-smoke` |
| Expected cost | ~$90–160 total (GPU ~$60–90 + OpenAI ~$30–70) |

## 1. Launching the PI pod

Provision the pod from the [Prime Intellect dashboard](https://app.primeintellect.ai/)
or via the `prime` CLI. The required attributes:

- **GPU**: 1× H200 141GB, on-demand. The run script is configured for
  single-GPU (`NUM_GPUS=1`, `--tensor-model-parallel-size 1`); the H200's
  141GB comfortably holds Qwen3-4B + Adam + ref model + colocated SGLang
  KV cache without sharding gymnastics.
  - **Alternative configs** (require editing `examples/tau-bench/run_qwen3_4B.sh`):
    - **2× H100 80GB**: set `NUM_GPUS=2` and `--tensor-model-parallel-size 2`.
      Faster wall-clock (~1.3-1.7× faster than 1× H200), but ~2× GPU cost.
    - **1× H100 80GB**: tight on memory (4B + Adam + ref + sglang ≈ 85 GB on
      80 GB budget). Workable only with optimizer CPU-offload or dropping
      the ref model; expect OOM debug time.
    - **1× B300 262 GB**: enormous memory headroom but Blackwell (sm_100)
      requires CUDA ≥ 12.8 — the `slimerl/slime:latest` base may not
      support Blackwell without a rebuild. Not recommended unless you've
      verified compatibility.
- **Image**: `ramneetsingh/slime-ssh:latest` (the SSH-enabled wrapper — see
  § 1a below; the upstream `slimerl/slime:latest` lacks `openssh-server` and
  cannot be SSHed into directly on PI).
- **Container Start Script** (Advanced section of the pod create form):
  paste the contents of `scripts/pi-image/start.sh` verbatim. PI populates
  `$PUBLIC_KEY` and `$SSH_PORT` at boot; the script wires them into sshd
  and execs sshd as PID 1.
- **Persistent volume**: not used for this run. Everything (model download,
  mcore conversion, checkpoint, logs) lives in `/workspace` on the ephemeral
  root disk. **Consequence**: if the pod restarts, all of it is lost and
  bootstrap must redo the model download (~5-15 min) and mcore conversion
  (~10-30 min). For a one-shot smoke run this is the pragmatic choice. To
  add persistence later, attach a volume mounted at `/workspace` — no
  script change required.
- **Root disk**: 150–200 GB. With no persistent volume, the root disk also
  has to hold the HF model (~8 GB), mcore conversion (~8 GB), final
  checkpoint, and logs — bump the recommendation accordingly.
- **SSH access**: enabled, with your public key.

> The `prime` CLI flag surface changes from release to release. Confirm the
> exact flag spellings against `prime --help` on the version you have
> installed before pasting a command into a runbook update. The web UI is
> the simplest path for a one-off pod.

## 1a. Build & push the PI image (one-time)

The wrapper Dockerfile lives at `scripts/pi-image/Dockerfile`. It does
nothing more than add `openssh-server` and PI's required sshd config on
top of the upstream slime image. Build it once, push to your registry, and
reuse the resulting tag for every future PI run:

```bash
docker build -t ramneetsingh/slime-ssh:latest scripts/pi-image
docker push ramneetsingh/slime-ssh:latest
```

Rebuild only if the upstream `slimerl/slime:latest` digest changes in a way
that matters to you (security update, dependency bump). The image is
intentionally a single thin layer so a rebuild is cheap.

## 2. First-time setup on the pod

After SSHing in:

```bash
export OPENAI_API_KEY=sk-...        # your OpenAI key (gpt-4o-mini)
export WANDB_API_KEY=...             # your wandb key
# Optional override of the wandb project (defaults to slime-tau-bench):
# export WANDB_PROJECT=slime-tau-bench

bash /root/slime/scripts/pi_bootstrap.sh
bash /root/slime/scripts/pi_launch_train.sh
```

`pi_bootstrap.sh` is idempotent — it clones slime + the JD-ETH tau-bench
fork, downloads the Qwen3-4B HF checkpoint, runs the mcore conversion, and
generates the mock train/dev jsonl files, all under `/workspace/`. Each
step skips itself if its artifact is already present.

`pi_launch_train.sh` starts the training run inside tmux session `slime-tau`
and tees stdout/stderr to `/workspace/logs/run-<timestamp>.log`. Reattach
with `tmux a -t slime-tau`. Detach again with `Ctrl-b d`.

## 3. Monitoring

- **Wandb**: project `slime-tau-bench`, group `qwen3-4B-pi-smoke`.
  Watch:
  - **Mean reward** — should start trending up by iteration 20–25.
  - **`retail-dev` eval reward** — improvement typically shows by iteration
    30–40. Eval runs every 5 iterations (`--eval-interval 5`).
  - **Rollout token throughput** — if it cliff-drops, the user-sim API is
    likely rate-limited; check OpenAI usage dashboard.
- **Tmux log**: `tail -f /workspace/logs/run-*.log` from a second SSH
  session, or reattach with `tmux a -t slime-tau`.
- **GPU utilization**: `nvidia-smi -l 5` from a second SSH session — both
  GPUs should stay near 100 % during the actor phase.

## 4. Recovery from pod restart

There's no persistent storage in this configuration, so a pod stop/start
loses **everything** in `/workspace` — model, mcore conversion, mock data,
checkpoint, logs. After a restart you have to start over from scratch:
re-SSH, re-export env vars, re-run bootstrap (which re-downloads + re-converts
the model — ~15–45 min), and re-launch training from iteration 0.

With `--save-interval 50` and `--num-rollout 50`, the only checkpoint is
written at the very end, so there's no intermediate save to resume from
anyway. Best practice: keep the pod up for the full run, and grab the
final checkpoint off the pod (e.g., `scp` or HF Hub upload) **before**
tearing it down.

If you want restart resilience later, attach a persistent volume mounted at
`/workspace` when creating the pod — the bootstrap will treat it the same
way and skip re-downloading artifacts already present.

## 5. Tear-down

When the run is done and you've pulled the final checkpoint off the pod
(e.g., `scp -P <port> root@<host>:/workspace/Qwen3-4B-Instruct-2507_slime/* .`
or upload directly to HF Hub from the pod), stop the pod from the PI
dashboard. There's no persistent volume to clean up in this configuration.

## 6. Cost ceiling and circuit-breakers

Investigate before continuing if any of these hold:

- **GPU clock > 12 h** on a single run (something is hung; the smoke run
  should complete in well under that).
- **OpenAI spend > $100** for this single run (the `check_reward_nonzero_std`
  filter inflates rollout count and is the most likely culprit; user has
  been warned, but a number significantly above $70 is anomalous).
- **Total cost projection > $160** — stop and reassess parameters before
  burning more.
