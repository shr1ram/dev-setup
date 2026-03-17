# dev-setup

Personal dev environment bootstrap. One command to set up a new machine.

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh)
```

## How It Works

1. Clones this repo and installs public configs (tmux, zsh, git, Claude Code)
2. Installs Homebrew packages, Tailscale, tap-to-tmux
3. Authenticates with GitHub (`gh auth login`)
4. Clones the **private** repo ([dev-setup-private](https://github.com/shr1ram/dev-setup-private)) and installs private configs (SSH, tap-to-tmux credentials, etc.)

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
