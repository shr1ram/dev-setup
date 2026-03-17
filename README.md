# dev-setup

Personal dev environment bootstrap. One command to set up a new machine.

Supports **macOS** and **Linux**. Windows is not currently supported.

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh)
```

Preview first with `--dry-run`:
```bash
bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh) --dry-run
```

## How It Works

1. Clones this repo to `~/dev-setup`
2. Installs Homebrew + packages (gh, git, tmux, pyenv, python, jq, curl)
3. Copies public configs (gitconfig, zshrc, tmux.conf, Claude Code settings)
4. Installs Tailscale, tap-to-tmux, TPM, nvm
5. Authenticates with GitHub (`gh auth login`)
6. Clones the **private** repo ([dev-setup-private](https://github.com/shr1ram/dev-setup-private)) and installs private configs (SSH, tap-to-tmux credentials)

Existing files are backed up before overwriting. Running again is safe — it skips what's already installed and pulls the latest configs.

## What It Sets Up

| Module     | What it does                                    | Repo    |
|------------|-------------------------------------------------|---------|
| `brew`     | Installs Homebrew + packages from Brewfile      | public  |
| `git`      | Git config (name, email)                        | public  |
| `shell`    | Zsh config, pyenv, nvm                          | public  |
| `tmux`     | tmux config + TPM plugin manager                | public  |
| `tap`      | [tap-to-tmux](https://github.com/flavio87/tap-to-tmux) install | public  |
| `tailscale`| Tailscale VPN                                   | public  |
| `claude`   | Claude Code settings, hooks, permissions        | public  |
| `ssh`      | SSH config (hosts, keys)                        | private |
| `tap` config | tap-to-tmux credentials (ntfy, Blink)        | private |

## Options

```bash
./setup.sh --skip-ssh          # Skip SSH config
./setup.sh --skip-claude       # Skip Claude Code setup
./setup.sh --skip-tmux         # Skip tmux
./setup.sh --skip-tap          # Skip tap-to-tmux
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
