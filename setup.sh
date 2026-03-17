#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Dev Environment Setup
# Usage: bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh)
#   or:  ./setup.sh [OPTIONS]
#
# Options:
#   --skip-ssh        Skip SSH setup (passed to private repo)
#   --skip-claude     Skip Claude Code setup
#   --skip-tmux       Skip tmux setup
#   --skip-tap        Skip tap-to-tmux setup
#   --skip-tailscale  Skip Tailscale setup
#   --skip-brew       Skip Homebrew package installation
#   --skip-shell      Skip shell (zsh) config setup
#   --skip-git        Skip git config setup
#   --skip-private    Skip private repo setup entirely
#   --only <module>   Run only the specified module
#   --dry-run         Show what would be done without making changes
#   -h, --help        Show this help message
# =============================================================================

REPO_URL="https://github.com/shr1ram/dev-setup.git"
PRIVATE_REPO_URL="https://github.com/shr1ram/dev-setup-private.git"
CLONE_DIR="$HOME/dev-setup"
PRIVATE_CLONE_DIR="$HOME/dev-setup-private"

# Defaults — all modules enabled
SKIP_SSH=false
SKIP_CLAUDE=false
SKIP_TMUX=false
SKIP_TAP=false
SKIP_TAILSCALE=false
SKIP_BREW=false
SKIP_SHELL=false
SKIP_GIT=false
SKIP_PRIVATE=false
DRY_RUN=false
ONLY_MODULE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
prompt_header() { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

usage() {
    sed -n '/^# =====/,/^# =====/p' "$0" | grep -v '=====' | sed 's/^# //'
    exit 0
}

# Parse arguments — collect all args to pass through to private script
ALL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-ssh)       SKIP_SSH=true ;;
        --skip-claude)    SKIP_CLAUDE=true ;;
        --skip-tmux)      SKIP_TMUX=true ;;
        --skip-tap)       SKIP_TAP=true ;;
        --skip-tailscale) SKIP_TAILSCALE=true ;;
        --skip-brew)      SKIP_BREW=true ;;
        --skip-shell)     SKIP_SHELL=true ;;
        --skip-git)       SKIP_GIT=true ;;
        --skip-private)   SKIP_PRIVATE=true ;;
        --only)
            ONLY_MODULE="$2"
            shift
            ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
    shift
done

# If --only is set, skip everything except that module
if [[ -n "$ONLY_MODULE" ]]; then
    SKIP_SSH=true; SKIP_CLAUDE=true; SKIP_TMUX=true; SKIP_TAP=true
    SKIP_TAILSCALE=true; SKIP_BREW=true; SKIP_SHELL=true; SKIP_GIT=true
    SKIP_PRIVATE=true
    case "$ONLY_MODULE" in
        ssh)       SKIP_SSH=false; SKIP_PRIVATE=false ;;
        claude)    SKIP_CLAUDE=false ;;
        tmux)      SKIP_TMUX=false ;;
        tap)       SKIP_TAP=false ;;
        tailscale) SKIP_TAILSCALE=false ;;
        brew)      SKIP_BREW=false ;;
        shell)     SKIP_SHELL=false ;;
        git)       SKIP_GIT=false ;;
        private)   SKIP_PRIVATE=false ;;
        *) error "Unknown module: $ONLY_MODULE"; exit 1 ;;
    esac
fi

# ─── Clone / update the public repo ─────────────────────────────────────────
setup_repo() {
    info "Setting up dev-setup repo..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would clone/update $REPO_URL -> $CLONE_DIR"
        return
    fi

    if [[ -d "$CLONE_DIR/.git" ]]; then
        info "Updating existing repo..."
        git -C "$CLONE_DIR" pull --ff-only
    else
        git clone "$REPO_URL" "$CLONE_DIR"
    fi
    ok "Repo ready at $CLONE_DIR"
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would backup $file -> $backup"
        else
            cp "$file" "$backup"
            warn "Backed up $file -> $backup"
        fi
    fi
}

install_config() {
    local src="$1"
    local dest="$2"
    backup_file "$dest"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would copy $src -> $dest"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    ok "Installed $dest"
}

# ─── Homebrew ────────────────────────────────────────────────────────────────
setup_brew() {
    if [[ "$SKIP_BREW" == true ]]; then return; fi
    info "Setting up Homebrew..."

    if ! command -v brew &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would install Homebrew"
        else
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [[ -f /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            fi
        fi
    else
        ok "Homebrew already installed"
    fi

    info "Installing packages from Brewfile..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would run: brew bundle --file=$CLONE_DIR/configs/Brewfile"
    else
        brew bundle --file="$CLONE_DIR/configs/Brewfile" --no-lock
    fi
}

# ─── Git ─────────────────────────────────────────────────────────────────────
setup_git() {
    if [[ "$SKIP_GIT" == true ]]; then return; fi
    info "Setting up Git config..."
    install_config "$CLONE_DIR/configs/gitconfig" "$HOME/.gitconfig"
}

# ─── GitHub Auth ─────────────────────────────────────────────────────────────
setup_gh_auth() {
    info "Checking GitHub authentication..."

    if gh auth status &>/dev/null; then
        ok "Already authenticated with GitHub"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would run: gh auth login"
        return
    fi

    info "GitHub authentication required for private repo access."
    gh auth login
}

# ─── Shell (Zsh) ─────────────────────────────────────────────────────────────
setup_shell() {
    if [[ "$SKIP_SHELL" == true ]]; then return; fi
    info "Setting up shell config..."
    install_config "$CLONE_DIR/configs/zshrc" "$HOME/.zshrc"

    if ! command -v pyenv &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would install pyenv"
        else
            brew install pyenv 2>/dev/null || true
        fi
    fi

    if [[ ! -d "$HOME/.nvm" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would install nvm"
        else
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        fi
    fi
}

# ─── SSH key generation ─────────────────────────────────────────────────────
setup_ssh_key() {
    if [[ "$SKIP_SSH" == true ]]; then return; fi
    info "Checking SSH key..."

    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
        ok "SSH key already exists"
        return
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would generate SSH key"
        return
    fi

    read -rp "Generate SSH key? Enter email (or press Enter to skip): " ssh_email
    if [[ -n "$ssh_email" ]]; then
        ssh-keygen -t ed25519 -C "$ssh_email" -f "$HOME/.ssh/id_ed25519"
        ok "SSH key generated."
        echo ""
        cat "$HOME/.ssh/id_ed25519.pub"
        echo ""
        info "Add to GitHub: gh ssh-key add ~/.ssh/id_ed25519.pub --title \"$(hostname)\""
    fi
}

# ─── Tmux ────────────────────────────────────────────────────────────────────
setup_tmux() {
    if [[ "$SKIP_TMUX" == true ]]; then return; fi
    info "Setting up tmux..."

    if ! command -v tmux &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would install tmux"
        else
            brew install tmux
        fi
    fi

    install_config "$CLONE_DIR/configs/tmux.conf" "$HOME/.tmux.conf"

    # Install TPM
    if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would install TPM"
        else
            git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
            ok "TPM installed. Press prefix + I inside tmux to install plugins."
        fi
    else
        ok "TPM already installed"
    fi
}

# ─── tap-to-tmux ─────────────────────────────────────────────────────────────
setup_tap() {
    if [[ "$SKIP_TAP" == true ]]; then return; fi
    info "Setting up tap-to-tmux..."

    local TAP_DIR="$HOME/tap-to-tmux"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would clone/update tap-to-tmux"
    else
        if [[ -d "$TAP_DIR/.git" ]]; then
            info "Updating existing tap-to-tmux..."
            git -C "$TAP_DIR" pull --ff-only
        else
            git clone https://github.com/flavio87/tap-to-tmux.git "$TAP_DIR"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would run tap-to-tmux install.sh"
    else
        if [[ -f "$TAP_DIR/install.sh" ]]; then
            bash "$TAP_DIR/install.sh"
            ok "tap-to-tmux installed"
        else
            warn "tap-to-tmux install.sh not found"
        fi
    fi
}

# ─── Tailscale ───────────────────────────────────────────────────────────────
setup_tailscale() {
    if [[ "$SKIP_TAILSCALE" == true ]]; then return; fi
    info "Setting up Tailscale..."

    if [[ "$(uname)" == "Darwin" ]]; then
        if [[ -d "/Applications/Tailscale.app" ]]; then
            ok "Tailscale already installed"
        else
            if [[ "$DRY_RUN" == true ]]; then
                info "[DRY RUN] Would install Tailscale via brew cask"
            else
                brew install --cask tailscale
            fi
        fi
        info "Open Tailscale from Applications and sign in to connect."
    else
        if command -v tailscale &>/dev/null; then
            ok "Tailscale already installed"
        else
            if [[ "$DRY_RUN" == true ]]; then
                info "[DRY RUN] Would install Tailscale via curl"
            else
                curl -fsSL https://tailscale.com/install.sh | sh
            fi
        fi
        info "Run 'sudo tailscale up' to connect."
    fi
}

# ─── Claude Code ─────────────────────────────────────────────────────────────
setup_claude() {
    if [[ "$SKIP_CLAUDE" == true ]]; then return; fi
    info "Setting up Claude Code..."

    if ! command -v claude &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY RUN] Would install Claude Code via npm"
        else
            if command -v npm &>/dev/null; then
                npm install -g @anthropic-ai/claude-code
            else
                warn "npm not found. Install Node.js first, then: npm install -g @anthropic-ai/claude-code"
            fi
        fi
    else
        ok "Claude Code already installed"
    fi

    mkdir -p "$HOME/.claude"
    install_config "$CLONE_DIR/configs/claude_settings.json" "$HOME/.claude/settings.json"
}

# ─── Private repo ───────────────────────────────────────────────────────────
setup_private() {
    if [[ "$SKIP_PRIVATE" == true ]]; then return; fi

    prompt_header "Private Config Setup"

    # Ensure GitHub auth is set up first
    setup_gh_auth

    info "Cloning private config repo..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would clone/update $PRIVATE_REPO_URL -> $PRIVATE_CLONE_DIR"
        info "[DRY RUN] Would run setup-private.sh"
        return
    fi

    if [[ -d "$PRIVATE_CLONE_DIR/.git" ]]; then
        info "Updating existing private repo..."
        git -C "$PRIVATE_CLONE_DIR" pull --ff-only
    else
        if ! git clone "$PRIVATE_REPO_URL" "$PRIVATE_CLONE_DIR" 2>/dev/null; then
            warn "Could not clone private repo. Check GitHub auth and repo access."
            return
        fi
    fi

    # Run private setup, passing through relevant flags
    local private_args=()
    [[ "$SKIP_SSH" == true ]] && private_args+=("--skip-ssh")
    [[ "$SKIP_TAP" == true ]] && private_args+=("--skip-tap")
    [[ "$DRY_RUN" == true ]] && private_args+=("--dry-run")

    bash "$PRIVATE_CLONE_DIR/setup-private.sh" "${private_args[@]}"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║       Dev Environment Setup          ║"
    echo "╚══════════════════════════════════════╝"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY RUN mode — no changes will be made"
        echo ""
    fi

    setup_repo
    setup_brew
    setup_git
    setup_shell
    setup_ssh_key
    setup_tmux
    setup_tap
    setup_tailscale
    setup_claude
    setup_private

    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║           Setup Complete!            ║"
    echo "╚══════════════════════════════════════╝"
    echo ""
    info "Restart your terminal for all changes to take effect."
}

main
