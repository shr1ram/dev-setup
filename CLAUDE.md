# dev-setup

Public dev environment bootstrap repo. Configs here are copied to their live locations by `setup.sh`.

## Key rules

- Files in `configs/` are the source of truth for their corresponding live config files.
- Never put private data (SSH hosts, API keys, IPs, credentials) in this repo — it's public.
- Private configs go in `dev-setup-private`.
- Work-specific (Orbital) tooling lives in `dev-setup-private/orbital/`, never here. It's optional: `--skip-orbital` must keep working, so the public setup must never depend on it.
- After editing configs, commit and push. Run `setup.sh` to apply.
