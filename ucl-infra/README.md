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

### Port layout
- `8770`/`8771` — reserved for the legacy static shim (broker never uses these).
- `8780+` — per-lease shim port on the GPU box (loopback).
- `8781+` — per-lease tunnel port on the app box (`localhost:<port>` → that shim).

### Lease state
`leases.json` (flock-guarded) maps `run_id → {box, shim_port, tunnel_port,
session_key, local, claimed_at, ...}`. Per-lease shim roots live under
`leases/<run_id>/`.

### Status
- **Phase 1 (these scripts):** done — claim/release/prune verified end-to-end.
- **Phase 2:** engine integration — `stage6_infra.py` claims per-experiment and
  releases on run-terminal (in the Memento repo, not here).
- **Phase 3:** same broker for a per-app Ollama (LLM) on its own GPU.
