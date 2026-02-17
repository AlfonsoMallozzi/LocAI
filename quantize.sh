#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  DeepHat Quantization Pipeline
#  Downloads DeepHat-V1-7B from HuggingFace → converts to GGUF → quantizes
#  Target: Arch Linux  |  Output: deephat-v1.Q4_K_M.gguf (~4.5 GB)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────
HF_REPO="DeepHat/DeepHat-V1-7B"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/.quantize-workdir"
MODEL_DIR="$WORK_DIR/model"
LLAMA_CPP_DIR="$WORK_DIR/llama.cpp"
GGUF_F16="$WORK_DIR/deephat-v1.f16.gguf"
GGUF_QUANT="$SCRIPT_DIR/deephat-v1.Q4_K_M.gguf"
QUANT_TYPE="Q4_K_M"

# ── Colors ──────────────────────────────────────────────────────────────
readonly RST='\033[0m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RED='\033[0;31m'
readonly GRN='\033[0;32m'
readonly YLW='\033[0;33m'
readonly CYN='\033[0;36m'
readonly WHT='\033[1;37m'

# ── Helpers ─────────────────────────────────────────────────────────────
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[  OK]${RST}  $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
fail()  { echo -e "${RED}[FAIL]${RST}  $*"; exit 1; }

header() {
    echo ""
    echo -e "${CYN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    echo -e "${CYN}${BOLD}  $*${RST}"
    echo -e "${CYN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────
preflight() {
    header "Pre-flight Checks"

    # Check available disk space (need ~30 GB)
    local avail_kb
    avail_kb=$(df --output=avail "$SCRIPT_DIR" 2>/dev/null | tail -1 | tr -d ' ')
    local avail_gb=$(( avail_kb / 1048576 ))
    if [[ $avail_gb -lt 25 ]]; then
        warn "Only ${avail_gb} GB free disk space. Need ~30 GB temporarily."
        echo -n "Continue anyway? [y/N] "
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    else
        ok "Disk space: ${avail_gb} GB available"
    fi

    # Check for git
    if ! command -v git &>/dev/null; then
        fail "git is not installed. Install with: sudo pacman -S git"
    fi
    ok "git found"

    # Check for Python 3
    if ! command -v python3 &>/dev/null; then
        fail "python3 is not installed. Install with: sudo pacman -S python"
    fi
    ok "python3 found: $(python3 --version 2>&1)"

    # Check for pip
    if ! python3 -m pip --version &>/dev/null; then
        warn "pip not found. Attempting install..."
        sudo pacman -S --noconfirm python-pip 2>/dev/null || fail "Could not install pip."
    fi
    ok "pip found"

    # Check for cmake + make (needed to build llama.cpp)
    if ! command -v cmake &>/dev/null; then
        fail "cmake is not installed. Install with: sudo pacman -S cmake"
    fi
    ok "cmake found"

    if ! command -v make &>/dev/null; then
        fail "make is not installed. Install with: sudo pacman -S make"
    fi
    ok "make found"

    # Check for a C++ compiler
    if ! command -v g++ &>/dev/null && ! command -v c++ &>/dev/null; then
        fail "C++ compiler not found. Install with: sudo pacman -S gcc"
    fi
    ok "C++ compiler found"
}

# ── Step 1: Install Python dependencies ─────────────────────────────────
install_python_deps() {
    header "Step 1/5 — Installing Python Dependencies"

    local deps=("huggingface_hub" "transformers" "torch" "sentencepiece" "protobuf" "numpy")

    info "Installing: ${deps[*]}"
    python3 -m pip install --upgrade "${deps[@]}" || fail "Failed to install Python dependencies."
    ok "Python dependencies installed"
}

# ── Step 2: Clone / Update llama.cpp ────────────────────────────────────
setup_llama_cpp() {
    header "Step 2/5 — Setting Up llama.cpp"

    mkdir -p "$WORK_DIR"

    if [[ -d "$LLAMA_CPP_DIR" ]]; then
        info "llama.cpp already cloned, pulling latest..."
        cd "$LLAMA_CPP_DIR"
        git pull --ff-only 2>/dev/null || warn "Could not pull latest (using existing version)"
    else
        info "Cloning llama.cpp..."
        git clone --depth 1 https://github.com/ggerganov/llama.cpp "$LLAMA_CPP_DIR"
    fi

    cd "$LLAMA_CPP_DIR"

    # Build the quantize tool
    info "Building llama.cpp (quantize tool)..."
    cmake -B build -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5
    cmake --build build --target llama-quantize -j "$(nproc)" 2>&1 | tail -10

    if [[ ! -f "$LLAMA_CPP_DIR/build/bin/llama-quantize" ]]; then
        fail "llama-quantize binary not found after build. Check build output."
    fi
    ok "llama.cpp built successfully"

    cd "$SCRIPT_DIR"
}

# ── Step 3: Download the model from HuggingFace ────────────────────────
download_model() {
    header "Step 3/5 — Downloading DeepHat-V1-7B from HuggingFace"

    mkdir -p "$MODEL_DIR"

    if [[ -d "$MODEL_DIR/config.json" ]] 2>/dev/null || [[ -f "$MODEL_DIR/config.json" ]]; then
        info "Model files already present in $MODEL_DIR"
        echo -n "Re-download? [y/N] "
        read -r ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            ok "Using existing model files"
            return
        fi
    fi

    info "Downloading $HF_REPO ..."
    info "This will download ~15 GB of model weights. Please be patient."
    echo ""

    python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='$HF_REPO',
    local_dir='$MODEL_DIR',
    local_dir_use_symlinks=False
)
print('Download complete!')
" || fail "Failed to download model from HuggingFace."

    ok "Model downloaded to $MODEL_DIR"
}

# ── Step 4: Convert to GGUF (F16) ──────────────────────────────────────
convert_to_gguf() {
    header "Step 4/5 — Converting to GGUF Format (F16)"

    if [[ -f "$GGUF_F16" ]]; then
        info "F16 GGUF already exists: $GGUF_F16"
        echo -n "Re-convert? [y/N] "
        read -r ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            ok "Using existing F16 GGUF"
            return
        fi
    fi

    local convert_script="$LLAMA_CPP_DIR/convert_hf_to_gguf.py"
    if [[ ! -f "$convert_script" ]]; then
        fail "convert_hf_to_gguf.py not found at $convert_script"
    fi

    info "Converting HuggingFace model → F16 GGUF..."
    info "This may take several minutes and use significant RAM."
    echo ""

    python3 "$convert_script" \
        "$MODEL_DIR" \
        --outfile "$GGUF_F16" \
        --outtype f16 \
        || fail "GGUF conversion failed."

    ok "F16 GGUF created: $GGUF_F16"
    ok "Size: $(du -h "$GGUF_F16" | cut -f1)"
}

# ── Step 5: Quantize to Q4_K_M ─────────────────────────────────────────
quantize_model() {
    header "Step 5/5 — Quantizing to $QUANT_TYPE"

    if [[ -f "$GGUF_QUANT" ]]; then
        info "Quantized GGUF already exists: $GGUF_QUANT"
        echo -n "Re-quantize? [y/N] "
        read -r ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            ok "Using existing quantized GGUF"
            return
        fi
    fi

    local quantize_bin="$LLAMA_CPP_DIR/build/bin/llama-quantize"
    if [[ ! -f "$quantize_bin" ]]; then
        fail "llama-quantize not found at $quantize_bin"
    fi

    info "Quantizing F16 → $QUANT_TYPE..."
    info "This will take a few minutes."
    echo ""

    "$quantize_bin" "$GGUF_F16" "$GGUF_QUANT" "$QUANT_TYPE" \
        || fail "Quantization failed."

    ok "Quantized GGUF created: $GGUF_QUANT"
    ok "Size: $(du -h "$GGUF_QUANT" | cut -f1)"
}

# ── Cleanup ─────────────────────────────────────────────────────────────
cleanup_intermediate() {
    echo ""
    echo -e "${WHT}Intermediate files in: $WORK_DIR${RST}"
    echo -e "${DIM}  Model download:  $(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1 || echo 'N/A')${RST}"
    echo -e "${DIM}  F16 GGUF:        $(du -h "$GGUF_F16" 2>/dev/null | cut -f1 || echo 'N/A')${RST}"
    echo -e "${DIM}  llama.cpp:       $(du -sh "$LLAMA_CPP_DIR" 2>/dev/null | cut -f1 || echo 'N/A')${RST}"
    echo ""
    echo -n "Delete intermediate files to free disk space? [Y/n] "
    read -r ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        info "Removing intermediate files..."
        rm -rf "$WORK_DIR"
        ok "Cleaned up. Only the quantized model remains."
    else
        info "Keeping intermediate files in $WORK_DIR"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────
summary() {
    header "Quantization Complete!"

    echo -e "  ${GRN}✔${RST}  Quantized model: ${WHT}$GGUF_QUANT${RST}"
    echo -e "  ${GRN}✔${RST}  Size:            ${WHT}$(du -h "$GGUF_QUANT" | cut -f1)${RST}"
    echo -e "  ${GRN}✔${RST}  Quantization:    ${WHT}$QUANT_TYPE${RST}"
    echo ""
    echo -e "  ${CYN}Next steps:${RST}"
    echo -e "    1. Load into Ollama:"
    echo -e "       ${DIM}ollama create deephat -f Modelfile${RST}"
    echo -e "    2. Test it:"
    echo -e "       ${DIM}ollama run deephat${RST}"
    echo -e "    3. Or use the control panel:"
    echo -e "       ${DIM}./deephat-ctl.sh${RST}  →  press ${WHT}[3]${RST} to load"
    echo ""
}

# ── Main ────────────────────────────────────────────────────────────────
main() {
    header "DeepHat-V1-7B Quantization Pipeline"
    echo -e "  ${DIM}HuggingFace model  →  GGUF  →  $QUANT_TYPE quantization${RST}"
    echo -e "  ${DIM}Output: $GGUF_QUANT${RST}"
    echo ""

    # Check if already done
    if [[ -f "$GGUF_QUANT" ]]; then
        ok "Quantized model already exists: $GGUF_QUANT"
        echo -n "Run the full pipeline again? [y/N] "
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    fi

    preflight
    install_python_deps
    setup_llama_cpp
    download_model
    convert_to_gguf
    quantize_model
    cleanup_intermediate
    summary
}

main "$@"
