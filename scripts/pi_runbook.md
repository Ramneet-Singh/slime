# PI smoke-run runbook — `examples/tau-bench/run_qwen3_4B.sh`

Operator playbook for running the unmodified tau-bench example on a Prime
Intellect on-demand pod as a baseline validation of the slime + PI pipeline.

This is a **before-Harbor** baseline. Do not patch in Harbor changes against
this run; spin a separate branch for that work and compare its curves to the
ones produced here.

## Run parameters (resolved decisions)

| Knob | Value |
|---|---|
| GPUs | 2× H100 80GB, on-demand (2× A100 80GB also accepted — see notes below) |
| Pod image | `ramneetsingh/slime-ssh:latest` (thin SSH wrapper over `slimerl/slime:latest` — see § 1a) |
| Persistent volume | 100 GB, mounted at `/data` |
| User simulator | OpenAI `gpt-4o-mini` via LiteLLM |
| `--num-rollout` | 50 |
| `--save-interval` | 50 (only the final checkpoint is written) |
| Dynamic sampling filter | `check_reward_nonzero_std` (as-shipped; inflates OpenAI cost 2-3×) |
| Monitoring | wandb project `slime-tau-bench`, group `qwen3-4B-pi-smoke` |
| Expected cost | ~$90–160 total (GPU ~$60–90 + OpenAI ~$30–70) |

## 1. Launching the PI pod

Provision the pod from the [Prime Intellect dashboard](https://app.primeintellect.ai/)
or via the `prime` CLI. The required attributes:

- **GPU**: 2× H100 80GB, on-demand (not spot — preemption is not worth a ~30 %
  discount on a single overnight run).
  - **2× A100 80GB on-demand is an accepted alternative** if H100 capacity is
    unavailable or noticeably more expensive on the day. No code changes
    required — the run uses no FP8 / TransformerEngine / Hopper-only features.
    Caveats:
    - **80GB only, not 40GB** — colocated SGLang + actor on Qwen3-4B with
      TP=2 and `--max-tokens-per-gpu 9216` is tight at 40GB.
    - Expect **~1.5–2× wall-clock vs H100** for BF16. Per-hour pricing is
      lower, so total GPU cost lands roughly comparable; the $160 ceiling
      below still holds.
    - **Prefer SXM4 over PCIe** if PI lets you pick — PCIe A100 pods may
      lack NVLink between the two cards, which hurts rollout sync
      throughput (the launch script auto-detects and continues either way).
- **Image**: `ramneetsingh/slime-ssh:latest` (the SSH-enabled wrapper — see
  § 1a below; the upstream `slimerl/slime:latest` lacks `openssh-server` and
  cannot be SSHed into directly on PI).
- **Container Start Script** (Advanced section of the pod create form):
  paste the contents of `scripts/pi-image/start.sh` verbatim. PI populates
  `$PUBLIC_KEY` and `$SSH_PORT` at boot; the script wires them into sshd
  and execs sshd as PID 1.
- **Persistent volume**: 100 GB, mounted at `/data`
- **Root disk**: 100–150 GB (the image + JIT/tmp caches are the dominant
  consumers; the persistent volume holds model + checkpoints).
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
generates the mock train/dev jsonl files, all under `/data/`. Each
step skips itself if its artifact is already present.

`pi_launch_train.sh` starts the training run inside tmux session `slime-tau`
and tees stdout/stderr to `/data/logs/run-<timestamp>.log`. Reattach
with `tmux a -t slime-tau`. Detach again with `Ctrl-b d`.

## 3. Monitoring

- **Wandb**: project `slime-tau-bench`, group `qwen3-4B-pi-smoke`.
  Watch:
  - **Mean reward** — should start trending up by iteration 20–25.
  - **`retail-dev` eval reward** — improvement typically shows by iteration
    30–40. Eval runs every 5 iterations (`--eval-interval 5`).
  - **Rollout token throughput** — if it cliff-drops, the user-sim API is
    likely rate-limited; check OpenAI usage dashboard.
- **Tmux log**: `tail -f /data/logs/run-*.log` from a second SSH
  session, or reattach with `tmux a -t slime-tau`.
- **GPU utilization**: `nvidia-smi -l 5` from a second SSH session — both
  GPUs should stay near 100 % during the actor phase.

## 4. Recovery from pod restart

The on-demand pod itself shouldn't preempt, but if you stop/start it or it
gets force-recycled:

1. Re-SSH and re-export `OPENAI_API_KEY` and `WANDB_API_KEY`.
2. `bash /root/slime/scripts/pi_bootstrap.sh` — idempotent; it will no-op on
   already-present artifacts.
3. `bash /root/slime/scripts/pi_launch_train.sh` — slime resumes from the
   last save in `/data/Qwen3-4B-Instruct-2507_slime/` because
   `--load` and `--save` point to the same directory.

Note: with `--save-interval 50` and `--num-rollout 50`, only the final
checkpoint is written. A restart before iteration 50 means restarting from
the original HF checkpoint, so prefer keeping the pod up for the full run.

## 5. Tear-down

When the run is done and you've pulled what you need off the volume:

1. Stop the pod from the PI dashboard.
2. The 100 GB persistent volume costs roughly $10/month if kept; either
   destroy it or keep it for the next iteration (the bootstrap will reuse
   the cached HF download, mcore conversion, and mock data).

## 6. Cost ceiling and circuit-breakers

Investigate before continuing if any of these hold:

- **GPU clock > 12 h** on a single run (something is hung; the smoke run
  should complete in well under that).
- **OpenAI spend > $100** for this single run (the `check_reward_nonzero_std`
  filter inflates rollout count and is the most likely culprit; user has
  been warned, but a number significantly above $70 is anomalous).
- **Total cost projection > $160** — stop and reassess parameters before
  burning more.
