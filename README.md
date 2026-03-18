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
5. Authenticates with GitHub and clones the **private** repo for SSH config

### Full (`--full`)
Everything in minimal, plus:
- Installs Homebrew + packages from Brewfile
- Installs pyenv
- Installs Tailscale

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
| `brew`     | Installs Homebrew + packages from Brewfile      | public  | full    |
| `shell`    | + pyenv install                                 | public  | full    |
| `tailscale`| Tailscale VPN                                   | public  | full    |

## Options

```bash
./setup.sh --full              # Full setup (install packages + configs)
./setup.sh --skip-ssh          # Skip SSH config
./setup.sh --skip-claude       # Skip Claude Code setup
./setup.sh --skip-tmux         # Skip tmux
./setup.sh --skip-tailscale    # Skip Tailscale
./setup.sh --skip-brew         # Skip Homebrew packages
./setup.sh --skip-shell        # Skip zsh/bash/csh config
./setup.sh --skip-git          # Skip git config
./setup.sh --skip-private      # Skip private repo entirely
./setup.sh --only tmux         # Only set up tmux
./setup.sh --dry-run           # Preview without making changes
```

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
