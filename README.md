# dev-setup

Personal dev environment bootstrap. One command to set up a new machine.

Supports **macOS** and **Linux**. Windows is not currently supported.

## Quick Install

**Minimal** (configs only — safe for servers/lab machines):
```bash
bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh)
```

**Full** (configs + install packages — for your own machines):
```bash
bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh) --full
```

Preview first with `--dry-run`:
```bash
bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh) --dry-run
```

## How It Works

### Minimal (default)
1. Clones this repo to `~/dev-setup`
2. Copies config files (gitconfig, zshrc, tmux.conf, Claude Code settings)
3. Generates SSH key if needed
4. Installs TPM (tmux plugin manager) if tmux is available
5. Authenticates with GitHub and clones the **private** repo for SSH config

### Full (`--full`)
Everything in minimal, plus:
- Installs Homebrew + packages (gh, git, tmux, pyenv, python)
- Installs Tailscale, nvm, pyenv, Claude Code

Existing files are backed up before overwriting. Running again is safe — it skips what's already installed and pulls the latest configs.

## What It Sets Up

| Module     | What it does                                    | Repo    | Mode    |
|------------|-------------------------------------------------|---------|---------|
| `git`      | Git config (name, email)                        | public  | minimal |
| `shell`    | Zsh config                                      | public  | minimal |
| `tmux`     | tmux config + TPM (if tmux available)            | public  | minimal |
| `claude`   | Claude Code settings, hooks, permissions        | public  | minimal |
| `ssh`      | SSH config (hosts, keys)                        | private | minimal |
| `brew`     | Installs Homebrew + packages from Brewfile      | public  | full    |
| `shell`    | + pyenv, nvm install                            | public  | full    |
| `tailscale`| Tailscale VPN                                   | public  | full    |
| `claude`   | + Claude Code install via npm                   | public  | full    |

## Options

```bash
./setup.sh --full              # Full setup (install packages + configs)
./setup.sh --skip-ssh          # Skip SSH config
./setup.sh --skip-claude       # Skip Claude Code setup
./setup.sh --skip-tmux         # Skip tmux
./setup.sh --skip-tailscale    # Skip Tailscale
./setup.sh --skip-brew         # Skip Homebrew packages
./setup.sh --skip-shell        # Skip zsh config
./setup.sh --skip-git          # Skip git config
./setup.sh --skip-private      # Skip private repo entirely
./setup.sh --only tmux         # Only set up tmux
./setup.sh --dry-run           # Preview without making changes
```

## Updating Configs

Configs in this repo are the source of truth. Don't edit live files (`~/.zshrc` etc.) directly — edit the source in `configs/`, commit, push, and re-run `setup.sh`.

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
│   ├── tmux.conf             # tmux config
│   └── claude_settings.json  # Claude Code settings + permissions
└── README.md
```
