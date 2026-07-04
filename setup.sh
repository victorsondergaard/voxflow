#!/bin/bash
# VoxFlow setup: installs Homebrew dependencies and downloads models.
# Idempotent — safe to run as many times as you like (SPEC R14).
set -u

MODELS_DIR="$HOME/Library/Application Support/VoxFlow/models"
WHISPER_BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
QWEN_URL="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"

ok()   { printf "  \033[32m✔\033[0m %s\n" "$1"; }
info() { printf "  \033[36m→\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✘\033[0m %s\n" "$1"; }

echo "VoxFlow setup"
echo "==============="
STATUS=0

# --- 1. Homebrew ---------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    # brew may exist but not be on PATH in this shell
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$p" ]; then eval "$("$p" shellenv)"; break; fi
    done
fi
if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is not installed."
    echo ""
    echo "  Install it first (one command, from https://brew.sh):"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo ""
    echo "  Then run ./setup.sh again."
    exit 1
fi
ok "Homebrew found: $(command -v brew)"

# --- 2. whisper.cpp and llama.cpp ----------------------------------------
for formula in whisper-cpp llama.cpp; do
    if brew list --formula "$formula" >/dev/null 2>&1; then
        ok "$formula already installed"
    else
        info "Installing $formula (this can take a few minutes)…"
        if brew install "$formula"; then
            ok "$formula installed"
        else
            fail "Failed to install $formula. Run 'brew install $formula' manually and re-run setup."
            exit 1
        fi
    fi
done

# Sanity: are the server binaries visible?
FOUND_WHISPER=""
FOUND_LLAMA=""
for dir in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$dir/whisper-server" ] && FOUND_WHISPER="$dir/whisper-server"
    [ -x "$dir/llama-server" ]   && FOUND_LLAMA="$dir/llama-server"
done
if [ -n "$FOUND_WHISPER" ]; then ok "whisper-server: $FOUND_WHISPER"; else fail "whisper-server binary not found after install"; STATUS=1; fi
if [ -n "$FOUND_LLAMA" ];   then ok "llama-server:   $FOUND_LLAMA";   else fail "llama-server binary not found after install";   STATUS=1; fi

# --- 3. Models ------------------------------------------------------------
mkdir -p "$MODELS_DIR"

# download <url> <destination> <min size in MB>
download() {
    url="$1"; dest="$2"; min_mb="$3"; name="$(basename "$dest")"
    if [ -f "$dest" ]; then
        size_mb=$(( $(stat -f%z "$dest" 2>/dev/null || echo 0) / 1048576 ))
        if [ "$size_mb" -ge "$min_mb" ]; then
            ok "$name already downloaded (${size_mb} MB)"
            return 0
        fi
        info "$name looks incomplete (${size_mb} MB) — re-downloading"
        rm -f "$dest"
    fi
    info "Downloading $name…"
    if curl -L --fail --progress-bar -o "$dest.part" "$url" && mv "$dest.part" "$dest"; then
        size_mb=$(( $(stat -f%z "$dest" 2>/dev/null || echo 0) / 1048576 ))
        if [ "$size_mb" -ge "$min_mb" ]; then
            ok "$name downloaded (${size_mb} MB)"
        else
            fail "$name downloaded but is only ${size_mb} MB — expected ≥ ${min_mb} MB. Delete it and retry."
            return 1
        fi
    else
        rm -f "$dest.part"
        fail "Download failed for $name. Check your connection and re-run ./setup.sh."
        return 1
    fi
}

download "$WHISPER_BASE_URL/ggml-base.en.bin" "$MODELS_DIR/ggml-base.en.bin" 100 || STATUS=1
download "$WHISPER_BASE_URL/ggml-small.bin"   "$MODELS_DIR/ggml-small.bin"   400 || STATUS=1
download "$QWEN_URL" "$MODELS_DIR/qwen2.5-1.5b-instruct-q4_k_m.gguf" 500 || STATUS=1

echo ""
if [ "$STATUS" -eq 0 ]; then
    echo "All set! Next steps:"
    echo "  1. ./build.sh"
    echo "  2. Open dist/VoxFlow.app (or move it to /Applications first)"
else
    echo "Setup finished with errors — scroll up, fix, and re-run ./setup.sh (it skips what's already done)."
fi
exit "$STATUS"
