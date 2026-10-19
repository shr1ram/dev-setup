# dev-setup

Personal dev environment bootstrap. One command to set up a new machine.

Supports **macOS** and **Linux**. Windows is not currently supported.

## Quick Install

**From bash/zsh:**
```bash
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash
```

**From tcsh/csh** (common on lab machines):
```csh
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash
```

**Full mode** (adds Homebrew, pyenv, Tailscale):
```bash
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --full
```

**Work Mac** (adds the Orbital work tooling, off by default; see [below](#with-or-without-orbital-work-tooling)):
```bash
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --orbital
```

**Combine flags** freely, in any order, after `bash -s --`. For example, Orbital tooling but leave SSH alone:
```bash
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --orbital --skip-ssh
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --full --orbital
```

Once installed, re-run (or change flags) from the local copy, which pulls the latest first:
```bash
~/dev-setup/setup.sh --orbital --skip-ssh
```

Preview first with `--dry-run`:
```bash
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --dry-run
```

## How It Works

### Minimal (default)
1. Clones this repo to `~/dev-setup`
2. Copies config files (gitconfig, zshrc, bashrc, cshrc, tmux.conf, Claude Code settings)
3. Installs core tools: nvm, Node.js LTS, Claude Code, gh, tmux
4. Generates SSH key if needed
5. Authenticates with GitHub and clones the **private** repo for SSH config (`~/.ssh/config`)

No Orbital tooling is installed unless you pass `--orbital` (or `--only orbital`).

### Full (`--full`)
Everything in minimal, plus:
- Installs Homebrew + packages from Brewfile
- Installs pyenv
- Installs Tailscale

### Orbital (`--orbital`, opt-in)
Adds the work tooling from the private repo's `orbital/` folder. On macOS it symlinks `~/.local/bin/gpu-login`, the GPU-session login helper. Nothing else is installed; see the private repo's `orbital/README.md` for usage and one-time setup. Combine it with any other flags, e.g. `--full --orbital` or `--orbital --skip-ssh`.

Existing files are backed up before overwriting (max 3 kept per file). Running again is safe — identical configs are skipped, and it only installs what's missing.

## What It Sets Up

| Module     | What it does                                    | Repo    | Mode    |
|------------|-------------------------------------------------|---------|---------|
| `git`      | Git config (name, email, credential helper)     | public  | minimal |
| `shell`    | Zsh, Bash, and tcsh/csh config + nvm + Node.js  | public  | minimal |
| `tmux`     | tmux install + config + TPM                     | public  | minimal |
| `gh`       | GitHub CLI (standalone binary)                  | public  | minimal |
| `claude`   | Claude Code install + settings, hooks, permissions | public  | minimal |
| `ssh`      | SSH config (hosts, keys)                        | private | minimal |
| `orbital`  | Orbital work tooling (`gpu-login` on PATH, macOS) | private | opt-in (`--orbital`) |
| `brew`     | Installs Homebrew + packages from Brewfile      | public  | full    |
| `shell`    | + pyenv install                                 | public  | full    |
| `tailscale`| Tailscale VPN                                   | public  | full    |

## Options

```bash
./setup.sh --full              # Full setup (install packages + configs)
./setup.sh --skip-ssh          # Skip SSH: no key generation, no private ~/.ssh/config
./setup.sh --skip-claude       # Skip Claude Code setup
./setup.sh --skip-tmux         # Skip tmux
./setup.sh --skip-tailscale    # Skip Tailscale
./setup.sh --skip-brew         # Skip Homebrew packages
./setup.sh --skip-shell        # Skip zsh/bash/csh config
./setup.sh --skip-git          # Skip git config
./setup.sh --skip-private      # Skip private repo entirely (no SSH config)
./setup.sh --orbital           # Also install Orbital work tooling (off by default)
./setup.sh --only tmux         # Only set up tmux
./setup.sh --only orbital      # Only set up the Orbital work tooling
./setup.sh --dry-run           # Preview without making changes
```

## With or without Orbital work tooling

Work-specific tooling for Orbital lives in the **private** repo under `orbital/`. It is **off by default**. The private repo itself (SSH config) still runs by default.

```bash
# Any machine (default): public + private (SSH config), no Orbital
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash

# Work Mac: also install the Orbital tooling
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --orbital

# No private repo at all (no GitHub auth, no SSH hosts, no Orbital)
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --skip-private

# Work Mac, Orbital tooling but don't touch ~/.ssh (no key generation, no ~/.ssh/config)
curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh | bash -s -- --orbital --skip-ssh

# Add only the Orbital tooling to an already set-up machine
~/dev-setup/setup.sh --only orbital
```

The Orbital step is macOS-only and only symlinks `~/.local/bin/gpu-login` to the private repo's copy; it installs nothing system-wide. Leaving out `--orbital` means it isn't installed, but it doesn't remove a link from an earlier run (`rm ~/.local/bin/gpu-login` does). `--orbital` has no effect with `--skip-private`. Usage docs are in the private repo at `orbital/README.md`.

## Updating Configs

Configs in this repo are the source of truth. Don't edit live files (`~/.zshrc`, `~/.bashrc`, `~/.cshrc`, etc.) directly — edit the source in `configs/`, commit, push, and re-run `setup.sh`.

## Structure

```
dev-setup/
├── setup.sh                  # Bootstrapper (clones repo, runs install.sh)
├── scripts/
│   └── install.sh            # Main installer (always runs from local copy)
├── CLAUDE.md                 # Instructions for Claude Code
├── configs/
│   ├── Brewfile              # Homebrew packages
│   ├── gitconfig             # Git config
│   ├── zshrc                 # Zsh config
│   ├── bashrc                # Bash config
│   ├── cshrc                 # tcsh/csh config (lab machines)
│   ├── tmux.conf             # tmux config
│   └── claude_settings.json  # Claude Code settings + permissions
└── README.md
```
