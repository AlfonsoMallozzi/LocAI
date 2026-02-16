#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  DeepHat Control Panel — Live TUI for managing the DeepHat AI backend
#  Target: Arch Linux  |  Dependencies: bash, curl, systemctl
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

# ── Colors & Symbols ────────────────────────────────────────────────────
readonly RST='\033[0m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RED='\033[0;31m'
readonly GRN='\033[0;32m'
readonly YLW='\033[0;33m'
readonly CYN='\033[0;36m'
readonly WHT='\033[1;37m'
readonly BG_RED='\033[41m'
readonly BG_GRN='\033[42m'
readonly BG_YLW='\033[43m'
readonly BG_BLU='\033[44m'

readonly PASS="${GRN}✔${RST}"
readonly FAIL="${RED}✘${RST}"
readonly WARN="${YLW}●${RST}"
readonly SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# ── State ───────────────────────────────────────────────────────────────
TUNNEL_PID=""
TUNNEL_LOG=$(mktemp /tmp/deephat-tunnel-XXXXXX.log 2>/dev/null || echo "/tmp/deephat-tunnel-$$.log")
TUNNEL_URL=""
REFRESH_INTERVAL=3
LAST_ACTION_MSG=""
LAST_ACTION_TIME=0

# Status cache (updated each cycle)
S_OLLAMA_BIN=0
S_OLLAMA_SVC=0
S_GGUF=0
S_MODEL=0
S_CORS=0
S_CF_BIN=0
S_TUNNEL=0

# ── Cleanup ─────────────────────────────────────────────────────────────
cleanup() {
    tput cnorm 2>/dev/null || true   # restore cursor
    tput sgr0  2>/dev/null || true   # reset attrs
    echo ""

    if [[ -n "$TUNNEL_PID" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo -e "${DIM}Tunnel process (PID $TUNNEL_PID) is still running.${RST}"
        echo -n "Kill it? [y/N] "
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            kill "$TUNNEL_PID" 2>/dev/null && echo "Tunnel stopped." || true
        else
            echo -e "Tunnel left running (PID $TUNNEL_PID). Kill later with: ${WHT}kill $TUNNEL_PID${RST}"
        fi
    fi

    rm -f "$TUNNEL_LOG" 2>/dev/null || true
    echo -e "${DIM}Goodbye.${RST}"
}
trap cleanup EXIT INT TERM

# ── Check Functions ─────────────────────────────────────────────────────
check_ollama_installed() {
    command -v ollama &>/dev/null && return 0 || return 1
}

check_ollama_running() {
    systemctl is-active --quiet ollama.service 2>/dev/null && return 0 || return 1
}

check_model_loaded() {
    local tags
    tags=$(curl -sf --connect-timeout 2 http://localhost:11434/api/tags 2>/dev/null) || return 1
    echo "$tags" | grep -qi "deephat" && return 0 || return 1
}

check_cors_configured() {
    local env_line
    env_line=$(systemctl show ollama.service --property=Environment 2>/dev/null) || return 1
    echo "$env_line" | grep -qi "OLLAMA_ORIGINS" && return 0 || return 1
}

check_gguf_exists() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "$script_dir/deephat-v1.Q4_K_M.gguf" ]] && return 0 || return 1
}

check_cloudflared_installed() {
    command -v cloudflared &>/dev/null && return 0 || return 1
}

check_tunnel_active() {
    # Check our managed tunnel first
    if [[ -n "$TUNNEL_PID" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        # Extract URL from log if we don't have it yet
        if [[ -z "$TUNNEL_URL" ]] && [[ -f "$TUNNEL_LOG" ]]; then
            TUNNEL_URL=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        fi
        return 0
    fi

    # Check for any externally started cloudflared tunnel
    if pgrep -f "cloudflared tunnel" &>/dev/null; then
        TUNNEL_URL="(external — check cloudflared output)"
        return 0
    fi

    TUNNEL_PID=""
    TUNNEL_URL=""
    return 1
}

# ── Run All Checks ──────────────────────────────────────────────────────
run_checks() {
    check_ollama_installed   && S_OLLAMA_BIN=1 || S_OLLAMA_BIN=0
    check_ollama_running     && S_OLLAMA_SVC=1 || S_OLLAMA_SVC=0
    check_gguf_exists        && S_GGUF=1       || S_GGUF=0
    check_model_loaded       && S_MODEL=1      || S_MODEL=0
    check_cors_configured    && S_CORS=1       || S_CORS=0
    check_cloudflared_installed && S_CF_BIN=1  || S_CF_BIN=0
    check_tunnel_active      && S_TUNNEL=1     || S_TUNNEL=0
}

# ── UI Helpers ──────────────────────────────────────────────────────────
status_icon() {
    [[ "$1" -eq 1 ]] && echo -e "$PASS" || echo -e "$FAIL"
}

action_hint() {
    # $1 = status, $2 = key number
    if [[ "$1" -eq 0 ]]; then
        echo -e "${DIM}→ press ${WHT}[$2]${RST}"
    else
        echo -e "${DIM}          ${RST}"
    fi
}

set_action_msg() {
    LAST_ACTION_MSG="$1"
    LAST_ACTION_TIME=$(date +%s)
}

# ── Draw Dashboard ──────────────────────────────────────────────────────
draw() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 60)
    local w=56
    [[ $cols -lt $w ]] && w=$((cols - 2))

    local hbar
    hbar=$(printf '═%.0s' $(seq 1 $((w - 2))))

    tput cup 0 0 2>/dev/null || echo -en "\033[H"

    # Header
    echo -e "${CYN}${BOLD}"
    echo -e "  ╔${hbar}╗"
    printf  "  ║%-*s║\n" $((w - 2)) "   DEEPHAT — BACKEND CONTROL PANEL"
    printf  "  ║%-*s║\n" $((w - 2)) "   Arch Linux  ·  $(date '+%H:%M:%S')"
    echo -e "  ╠${hbar}╣${RST}"

    # Status rows
    local icon hint

    icon=$(status_icon $S_OLLAMA_BIN); hint=$(action_hint $S_OLLAMA_BIN 1)
    printf "  ${CYN}║${RST}  [%b]  Ollama installed            %b ${CYN}║${RST}\n" "$icon" "$hint"

    icon=$(status_icon $S_OLLAMA_SVC); hint=$(action_hint $S_OLLAMA_SVC 2)
    printf "  ${CYN}║${RST}  [%b]  Ollama service running       %b ${CYN}║${RST}\n" "$icon" "$hint"

    icon=$(status_icon $S_GGUF); hint=$(action_hint $S_GGUF 3)
    printf "  ${CYN}║${RST}  [%b]  GGUF model quantized         %b ${CYN}║${RST}\n" "$icon" "$hint"

    icon=$(status_icon $S_MODEL); hint=$(action_hint $S_MODEL 4)
    printf "  ${CYN}║${RST}  [%b]  deephat model loaded         %b ${CYN}║${RST}\n" "$icon" "$hint"

    icon=$(status_icon $S_CORS); hint=$(action_hint $S_CORS 5)
    printf "  ${CYN}║${RST}  [%b]  CORS configured              %b ${CYN}║${RST}\n" "$icon" "$hint"

    icon=$(status_icon $S_CF_BIN); hint=$(action_hint $S_CF_BIN 6)
    printf "  ${CYN}║${RST}  [%b]  cloudflared installed         %b ${CYN}║${RST}\n" "$icon" "$hint"

    icon=$(status_icon $S_TUNNEL); hint=$(action_hint $S_TUNNEL 7)
    printf "  ${CYN}║${RST}  [%b]  Tunnel active                %b ${CYN}║${RST}\n" "$icon" "$hint"

    # Separator
    echo -e "  ${CYN}╠${hbar}╣${RST}"

    # Tunnel URL
    if [[ $S_TUNNEL -eq 1 ]] && [[ -n "$TUNNEL_URL" ]]; then
        printf "  ${CYN}║${RST}  ${GRN}URL:${RST} %-*s ${CYN}║${RST}\n" $((w - 9)) "$TUNNEL_URL"
    else
        printf "  ${CYN}║${RST}  ${DIM}URL: (not active)%-*s${RST} ${CYN}║${RST}\n" $((w - 23)) ""
    fi

    # Separator
    echo -e "  ${CYN}╠${hbar}╣${RST}"

    # Overall status
    local total=$((S_OLLAMA_BIN + S_OLLAMA_SVC + S_GGUF + S_MODEL + S_CORS + S_CF_BIN + S_TUNNEL))
    if [[ $total -eq 7 ]]; then
        printf "  ${CYN}║${RST}  ${BG_GRN}${WHT} ALL SYSTEMS GO ${RST}%-*s ${CYN}║${RST}\n" $((w - 21)) ""
    else
        printf "  ${CYN}║${RST}  ${BG_RED}${WHT} %d/7 CHECKS PASSING ${RST}%-*s ${CYN}║${RST}\n" "$total" $((w - 25)) ""
    fi

    # Separator
    echo -e "  ${CYN}╠${hbar}╣${RST}"

    # Action message area
    local now
    now=$(date +%s)
    if [[ -n "$LAST_ACTION_MSG" ]] && [[ $((now - LAST_ACTION_TIME)) -lt 10 ]]; then
        printf "  ${CYN}║${RST}  ${YLW}▸${RST} %-*s ${CYN}║${RST}\n" $((w - 6)) "$LAST_ACTION_MSG"
    else
        printf "  ${CYN}║${RST}  %-*s ${CYN}║${RST}\n" $((w - 4)) ""
        LAST_ACTION_MSG=""
    fi

    # Footer
    echo -e "  ${CYN}╠${hbar}╣${RST}"
    printf "  ${CYN}║${RST}  ${WHT}[1-7]${RST} Fix issue  ${WHT}[r]${RST} Refresh  ${WHT}[q]${RST} Quit%-*s ${CYN}║${RST}\n" $((w - 44)) ""
    echo -e "  ${CYN}╚${hbar}╝${RST}"

    # Clear any lines below the dashboard from previous renders
    tput el 2>/dev/null || true
    echo -e "${DIM}  Auto-refresh every ${REFRESH_INTERVAL}s · $(date '+%Y-%m-%d')${RST}"
    tput el 2>/dev/null || true
}

# ── Action Functions ────────────────────────────────────────────────────
action_install_ollama() {
    if [[ $S_OLLAMA_BIN -eq 1 ]]; then
        set_action_msg "Ollama is already installed."
        return
    fi
    tput cnorm 2>/dev/null || true
    clear
    echo -e "${WHT}Installing Ollama...${RST}"
    echo -e "${DIM}Running: yay -S --noconfirm ollama-bin${RST}"
    echo ""
    if command -v yay &>/dev/null; then
        yay -S --noconfirm ollama-bin && set_action_msg "Ollama installed!" || set_action_msg "Install failed. Check output above."
    elif command -v paru &>/dev/null; then
        paru -S --noconfirm ollama-bin && set_action_msg "Ollama installed!" || set_action_msg "Install failed. Check output above."
    else
        echo -e "${RED}No AUR helper found. Install yay or paru first.${RST}"
        set_action_msg "No AUR helper found (need yay or paru)."
    fi
    echo ""
    echo -e "${DIM}Press any key to return...${RST}"
    read -rsn1
    tput civis 2>/dev/null || true
}

action_start_ollama() {
    if [[ $S_OLLAMA_SVC -eq 1 ]]; then
        set_action_msg "Ollama service is already running."
        return
    fi
    set_action_msg "Starting Ollama service..."
    sudo systemctl enable --now ollama.service 2>/dev/null \
        && set_action_msg "Ollama service started!" \
        || set_action_msg "Failed to start Ollama. Run manually."
}

action_quantize_model() {
    if [[ $S_GGUF -eq 1 ]]; then
        set_action_msg "GGUF model already exists."
        return
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local quantize_script="$script_dir/quantize.sh"

    tput cnorm 2>/dev/null || true
    clear

    if [[ ! -f "$quantize_script" ]]; then
        echo -e "${RED}quantize.sh not found at: $quantize_script${RST}"
        set_action_msg "quantize.sh not found."
        echo ""
        echo -e "${DIM}Press any key to return...${RST}"
        read -rsn1
        tput civis 2>/dev/null || true
        return
    fi

    echo -e "${WHT}Running DeepHat Quantization Pipeline...${RST}"
    echo -e "${DIM}This will download ~15 GB, convert, and quantize the model.${RST}"
    echo -e "${DIM}You need ~30 GB of free disk space temporarily.${RST}"
    echo ""
    echo -n "Continue? [y/N] "
    read -r ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        set_action_msg "Quantization cancelled."
        tput civis 2>/dev/null || true
        return
    fi

    bash "$quantize_script" && set_action_msg "GGUF model quantized!" || set_action_msg "Quantization failed. Check output."

    echo ""
    echo -e "${DIM}Press any key to return...${RST}"
    read -rsn1
    tput civis 2>/dev/null || true
}

action_load_model() {
    if [[ $S_MODEL -eq 1 ]]; then
        set_action_msg "deephat model is already loaded."
        return
    fi

    # Find the Modelfile relative to the script's location
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local modelfile="$script_dir/Modelfile"

    tput cnorm 2>/dev/null || true
    clear
    echo -e "${WHT}Load the deephat model${RST}"
    echo ""

    if [[ -f "$modelfile" ]]; then
        echo -e "  ${WHT}[1]${RST} ${GRN}Create from Modelfile${RST} ${DIM}(recommended)${RST}"
        echo -e "      ${DIM}Found: $modelfile${RST}"
    else
        echo -e "  ${WHT}[1]${RST} ${RED}Create from Modelfile${RST} ${DIM}(not found)${RST}"
    fi
    echo -e "  ${WHT}[2]${RST} Pull from Ollama registry: ${DIM}ollama pull deephat${RST}"
    echo -e "  ${WHT}[3]${RST} Pull a substitute model (llama3, mistral, etc.)"
    echo -e "  ${WHT}[q]${RST} Cancel"
    echo ""
    echo -n "Choice: "
    read -rsn1 choice
    echo ""
    case "$choice" in
        1)
            if [[ ! -f "$modelfile" ]]; then
                echo -e "${RED}No Modelfile found at: $modelfile${RST}"
                echo -e "${DIM}Make sure the Modelfile is in the same directory as this script.${RST}"
                set_action_msg "No Modelfile found."
            else
                # Extract the base model name from the Modelfile (FROM line)
                local base_model
                base_model=$(grep -iP '^\s*FROM\s+' "$modelfile" | head -1 | awk '{print $2}')

                if [[ -z "$base_model" ]]; then
                    echo -e "${RED}Could not parse base model from Modelfile.${RST}"
                    set_action_msg "Modelfile has no FROM line."
                else
                    # Check if base model is a local file path or a registry model
                    if [[ "$base_model" == ./* ]] || [[ "$base_model" == /* ]]; then
                        echo -e "${DIM}Base model is a local file: $base_model${RST}"
                        if [[ ! -f "$script_dir/$base_model" ]] && [[ ! -f "$base_model" ]]; then
                            echo -e "${RED}File not found: $base_model${RST}"
                            set_action_msg "Base model file not found."
                            echo ""
                            echo -e "${DIM}Press any key to return...${RST}"
                            read -rsn1
                            tput civis 2>/dev/null || true
                            return
                        fi
                    else
                        # It's a registry model — check if already pulled
                        echo -e "${WHT}Base model: ${CYN}$base_model${RST}"
                        if ! ollama list 2>/dev/null | grep -qi "$(echo "$base_model" | cut -d: -f1)"; then
                            echo -e "${YLW}Base model not found locally. Pulling...${RST}"
                            echo -e "${DIM}Running: ollama pull $base_model${RST}"
                            echo ""
                            if ! ollama pull "$base_model"; then
                                echo -e "${RED}Failed to pull base model.${RST}"
                                set_action_msg "Failed to pull $base_model."
                                echo ""
                                echo -e "${DIM}Press any key to return...${RST}"
                                read -rsn1
                                tput civis 2>/dev/null || true
                                return
                            fi
                            echo ""
                            echo -e "${GRN}Base model pulled!${RST}"
                        else
                            echo -e "${GRN}Base model already available.${RST}"
                        fi
                    fi

                    echo ""
                    echo -e "${WHT}Creating deephat model...${RST}"
                    echo -e "${DIM}Running: ollama create deephat -f $modelfile${RST}"
                    echo ""
                    if ollama create deephat -f "$modelfile"; then
                        set_action_msg "deephat model created!"
                        echo -e "${GRN}Done! deephat model is ready.${RST}"
                    else
                        set_action_msg "Failed to create model."
                        echo -e "${RED}Failed. Check output above.${RST}"
                    fi
                fi
            fi
            ;;
        2)
            echo -e "${DIM}Running: ollama pull deephat${RST}"
            ollama pull deephat && set_action_msg "deephat model pulled!" || set_action_msg "Pull failed."
            ;;
        3)
            echo -n "Model name to pull (e.g. llama3:8b): "
            read -r model_name
            if [[ -n "$model_name" ]]; then
                echo -e "${DIM}Running: ollama pull $model_name${RST}"
                ollama pull "$model_name" && set_action_msg "Pulled $model_name! Rename in frontend settings." || set_action_msg "Pull failed."
            fi
            ;;
        *)
            set_action_msg "Cancelled."
            ;;
    esac
    echo ""
    echo -e "${DIM}Press any key to return...${RST}"
    read -rsn1
    tput civis 2>/dev/null || true
}

action_fix_cors() {
    if [[ $S_CORS -eq 1 ]]; then
        set_action_msg "CORS is already configured."
        return
    fi

    local override_dir="/etc/systemd/system/ollama.service.d"
    local override_file="$override_dir/override.conf"

    set_action_msg "Configuring CORS..."

    # Create the override
    sudo mkdir -p "$override_dir" 2>/dev/null
    echo -e '[Service]\nEnvironment="OLLAMA_ORIGINS=*"' | sudo tee "$override_file" >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        sudo systemctl daemon-reload 2>/dev/null
        sudo systemctl restart ollama.service 2>/dev/null
        set_action_msg "CORS configured & Ollama restarted!"
    else
        set_action_msg "Failed to write override. Run with sudo?"
    fi
}

action_install_cloudflared() {
    if [[ $S_CF_BIN -eq 1 ]]; then
        set_action_msg "cloudflared is already installed."
        return
    fi
    tput cnorm 2>/dev/null || true
    clear
    echo -e "${WHT}Installing cloudflared...${RST}"
    echo -e "${DIM}Running: yay -S --noconfirm cloudflared-bin${RST}"
    echo ""
    if command -v yay &>/dev/null; then
        yay -S --noconfirm cloudflared-bin && set_action_msg "cloudflared installed!" || set_action_msg "Install failed."
    elif command -v paru &>/dev/null; then
        paru -S --noconfirm cloudflared-bin && set_action_msg "cloudflared installed!" || set_action_msg "Install failed."
    else
        echo -e "${RED}No AUR helper found. Install yay or paru first.${RST}"
        set_action_msg "No AUR helper found."
    fi
    echo ""
    echo -e "${DIM}Press any key to return...${RST}"
    read -rsn1
    tput civis 2>/dev/null || true
}

action_start_tunnel() {
    if [[ $S_TUNNEL -eq 1 ]]; then
        set_action_msg "Tunnel is already active."
        return
    fi

    if ! command -v cloudflared &>/dev/null; then
        set_action_msg "cloudflared not installed. Press [5] first."
        return
    fi

    set_action_msg "Starting Cloudflare Tunnel..."

    # Clear old log
    : > "$TUNNEL_LOG"
    TUNNEL_URL=""

    # Launch in background
    cloudflared tunnel --url http://localhost:11434 > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Wait a few seconds for URL to appear
    local tries=0
    while [[ $tries -lt 15 ]]; do
        sleep 1
        TUNNEL_URL=$(grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
        if [[ -n "$TUNNEL_URL" ]]; then
            set_action_msg "Tunnel active! URL shown below."
            return
        fi
        tries=$((tries + 1))
        set_action_msg "Starting tunnel... ($tries/15)"
        run_checks
        draw
    done

    # Check if process died
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        set_action_msg "Tunnel process died. Check logs."
        TUNNEL_PID=""
    else
        set_action_msg "Tunnel started but URL not captured yet. Will appear on refresh."
    fi
}

# ── Main Loop ───────────────────────────────────────────────────────────
main() {
    # Require a real terminal
    if ! tty -s; then
        echo "Error: deephat-ctl requires an interactive terminal." >&2
        exit 1
    fi

    # Check minimum terminal size
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)
    if [[ $rows -lt 20 ]] || [[ $cols -lt 50 ]]; then
        echo "Terminal too small (need at least 50×20, got ${cols}×${rows})." >&2
        exit 1
    fi

    # Hide cursor, clear screen
    tput civis 2>/dev/null || true
    clear

    while true; do
        run_checks
        draw

        # Wait for input or timeout (auto-refresh)
        local key=""
        read -rsn1 -t "$REFRESH_INTERVAL" key || true

        case "$key" in
            q|Q)
                break
                ;;
            r|R)
                set_action_msg "Refreshing..."
                ;;
            1)
                action_install_ollama
                clear
                ;;
            2)
                action_start_ollama
                ;;
            3)
                action_quantize_model
                clear
                ;;
            4)
                action_load_model
                clear
                ;;
            5)
                action_fix_cors
                ;;
            6)
                action_install_cloudflared
                clear
                ;;
            7)
                action_start_tunnel
                ;;
            "")
                # Timeout — just re-draw
                ;;
            *)
                set_action_msg "Unknown key: $key"
                ;;
        esac
    done
}

main "$@"
