# UCL experiment-infra + GPU broker

Deployment-side scripts for the Memento/AutoResearch pipeline on UCL lab GPUs.
These are versioned here (on the `ucl-memento` branch) but **deployed to**
`/cs/student/project_msc/2025/csml/sruppage/ucl-infra/` on the GPU box, where
they run. `server.py`, `session_key`, `runs.json`, `workspace/`, and the
`leases/` state live on the box and are NOT in git.

## Dynamic GPU broker (Phase 1)

Gives each experiment run its **own** GPU so runs never share — finding a free
GPU, standing up an infra shim there, and tearing it down when done.

| Script | Purpose |
|--------|---------|
| `gpu-broker-lib.sh` | Shared helpers (lease file + flock, free-GPU scan, port pools). Sourced, not run. |
| `claim-gpu.sh <run_id> [holder]` | Claim a GPU: pick a free box (**the app's own serving box first**, then other free lab boxes), start a shim there in a per-lease root, open a loopback tunnel, record the lease. Prints `{INFRA_SERVER_URL, INFRA_SESSION_KEY, box, local}` JSON. Idempotent per `run_id`. Exit 3 = no free GPU. |
| `release-gpu.sh <run_id>` | Tear down a lease: kill its tunnel, stop its shim, remove its root + lease entry. Idempotent (missing lease = no-op), so it's safe on every run-terminal path. |
| `gpu-leases.sh [--prune\|--json\|--list]` | List leases; `--prune` reaps leases whose tunnel is dead (recovers GPUs leaked by an app crash / killed run). Safe from cron / the watchdog. |
| `start-infra-shim.sh` | Start one shim (idempotent). **ROOT-aware**: honours `INFRA_SHIM_ROOT` so per-lease shims don't collide on key/workspace/runs. Legacy static path leaves it unset. |
| `claim-llm-gpu.sh <holder>` | **Phase 3.** Claim a GPU for an app's local LLM: start the Ollama wake-proxy on a free box, tunnel to it, return the `DEFAULT_API_BASE_URL`. Lease key `llm:<holder>`. |
| `llm-up.sh <app>` / `llm-down.sh <app>` | Operator wrappers: `eval "$(llm-up.sh serve)"` exports `DEFAULT_API_BASE_URL` for an app's dedicated LLM GPU; `llm-down.sh` releases it. Run around app start/stop on the `local` profile. |

### Port layout
- `8770`/`8771` — reserved for the legacy static shim (broker never uses these).
- `8780+` — per-lease shim port on the GPU box (loopback).
- `8781+` — per-lease tunnel port on the app box (`localhost:<port>` → that shim).

### Lease state
`leases.json` (flock-guarded) maps `run_id → {box, shim_port, tunnel_port,
session_key, local, claimed_at, ...}`. Per-lease shim roots live under
`leases/<run_id>/`.

### Status — all three phases done
- **Phase 1** (these scripts): claim/release/prune for experiment GPUs — verified.
- **Phase 2** (Memento repo `core/gpu_broker.py` + `pipeline_engine.py`): the
  engine claims a dedicated GPU per Stage-6 experiment (keyed on `project_id`)
  and releases on finalize + every terminal path. Gated by `GPU_BROKER=1`;
  fail-open to the static shim otherwise.
- **Phase 3** (`claim-llm-gpu.sh` + `llm-up.sh`/`llm-down.sh`): a per-app Ollama
  on its own GPU, reusing the same lease machinery. Operator-driven around app
  start/stop on the `local` profile (keeps the app boot path untouched).

### Enabling
- Experiments: set `GPU_BROKER=1` in the app's env. Off by default (static shim).
- LLM: run `eval "$(ucl-infra/llm-up.sh <app>)"` before starting a `local`-profile
  app; `ucl-infra/llm-down.sh <app>` on shutdown.
- Hygiene: run `ucl-infra/gpu-leases.sh --prune` from cron / the watchdog to reap
  any lease a crash leaked.
