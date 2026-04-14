#!/usr/bin/env bash
# =============================================================================
# LGCL — Linux Gaming Compatibility Layer Manager
# Version: 4.0.0 | Production-Grade Anti-Cheat-Aware Systems Platform
# =============================================================================
# Architecture: Multi-profile, transactional, hardware-adaptive, stealth-first
# Supported: Arch | Debian/Ubuntu | Fedora/RHEL
# Anti-cheat: EAC (kernel/userspace), BattlEye (kernel/userspace)
# License: MIT
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# SECTION 0 — CONSTANTS, IDENTITY, BOOTSTRAP
# =============================================================================

readonly LGCL_VERSION="4.0.0"
readonly LGCL_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/lgcl"
readonly LGCL_STATE_DIR="${LGCL_HOME}/state"
readonly LGCL_SNAPSHOT_DIR="${LGCL_HOME}/snapshots"
readonly LGCL_PROFILE_DIR="${LGCL_HOME}/profiles"
readonly LGCL_LOG_DIR="${LGCL_HOME}/logs"
readonly LGCL_RUNTIME_DIR="${LGCL_HOME}/runtimes"
readonly LGCL_LOCK_FILE="${LGCL_HOME}/lgcl.lock"
readonly LGCL_CURRENT_PROFILE_FILE="${LGCL_STATE_DIR}/current_profile"
readonly LGCL_APPLIED_SNAPSHOT_FILE="${LGCL_STATE_DIR}/applied_snapshot"

readonly LOG_FILE="${LGCL_LOG_DIR}/lgcl-$(date +%Y%m%d-%H%M%S)-$$.log"
readonly DRY_RUN_FILE="${LGCL_HOME}/dry_run.log"

# Steam canonical paths (respect Steam's own layout — never bypass it)
readonly STEAM_ROOT="${HOME}/.steam/root"
readonly STEAM_COMPAT_DIR="${STEAM_ROOT}/compatibilitytools.d"
readonly STEAM_RUNTIME_DIR="${HOME}/.steam/steam/steamapps/common"
readonly STEAM_CONFIG_DIR="${HOME}/.steam/steam/config"

# Anti-cheat runtime names as Steam manages them (do NOT rename or relocate)
readonly EAC_RUNTIME_NAME="Proton EasyAntiCheat Runtime"
readonly BATTLEYE_RUNTIME_NAME="Proton BattlEye Runtime"

# Official Proton AppIDs — used to detect Steam-managed runtime presence
readonly PROTON_APPID_EAC="1826330"
readonly PROTON_APPID_BATTLEYE="1161040"

# =============================================================================
# SECTION 1 — TERMINAL PRESENTATION LAYER
# =============================================================================

readonly C_RED='\033[0;31m'     C_BRED='\033[1;31m'
readonly C_GREEN='\033[0;32m'   C_BGREEN='\033[1;32m'
readonly C_YELLOW='\033[0;33m'  C_BYELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'    C_BBLUE='\033[1;34m'
readonly C_CYAN='\033[0;36m'    C_BCYAN='\033[1;36m'
readonly C_MAGENTA='\033[0;35m' C_BMAGENTA='\033[1;35m'
readonly C_BOLD='\033[1m'       C_DIM='\033[2m'
readonly C_RESET='\033[0m'

# Risk classification badge colors
badge_safe()    { echo -e "${C_BGREEN}[SAFE]${C_RESET}"; }
badge_caution() { echo -e "${C_BYELLOW}[CAUTION]${C_RESET}"; }
badge_unsafe()  { echo -e "${C_BRED}[UNSAFE]${C_RESET}"; }

_ts()     { date '+%Y-%m-%d %H:%M:%S'; }
_log()    { local lvl="$1"; shift; echo "$(_ts) [${lvl}] $*" >> "${LOG_FILE}"; }
log_dbg() { _log "DEBUG" "$*"; }
log_info(){ echo -e "${C_BBLUE}[INFO]${C_RESET} $*"; _log "INFO"  "$*"; }
log_ok()  { echo -e "${C_BGREEN}[ OK ]${C_RESET} $*"; _log "OK"    "$*"; }
log_warn(){ echo -e "${C_BYELLOW}[WARN]${C_RESET} $*"; _log "WARN"  "$*"; }
log_err() { echo -e "${C_BRED}[ERR ]${C_RESET} $*" >&2; _log "ERROR" "$*"; }
log_fatal(){ echo -e "${C_BRED}[FATAL]${C_RESET} $*" >&2; _log "FATAL" "$*"; _cleanup_and_exit 1; }

log_risk() {
    # Usage: log_risk SAFE|CAUTION|UNSAFE "description" "rationale"
    local level="$1" desc="$2" rationale="${3:-}"
    case "$level" in
        SAFE)    echo -e "  $(badge_safe)    ${desc}"; [[ -n "$rationale" ]] && echo -e "             ${C_DIM}↳ ${rationale}${C_RESET}" ;;
        CAUTION) echo -e "  $(badge_caution) ${desc}"; [[ -n "$rationale" ]] && echo -e "             ${C_DIM}↳ ${rationale}${C_RESET}" ;;
        UNSAFE)  echo -e "  $(badge_unsafe)  ${desc}"; [[ -n "$rationale" ]] && echo -e "             ${C_DIM}↳ ${rationale}${C_RESET}" ;;
    esac
    _log "RISK:${level}" "${desc} | ${rationale}"
}

log_section() {
    local title="$1"
    local w=72
    echo ""
    printf "${C_BOLD}${C_BCYAN}"; printf '═%.0s' $(seq 1 $w); printf "${C_RESET}\n"
    local pad=$(( (w - ${#title} - 2) / 2 ))
    printf "${C_BOLD}${C_BCYAN}"; printf '═%.0s' $(seq 1 $pad)
    printf " ${title} "
    printf '═%.0s' $(seq 1 $pad); printf "${C_RESET}\n"
    printf "${C_BOLD}${C_BCYAN}"; printf '═%.0s' $(seq 1 $w); printf "${C_RESET}\n\n"
    _log "SECTION" "=== ${title} ==="
}

spinner() {
    local pid="$1" msg="${2:-Working}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}${frames[$((i % 10))]}${C_RESET} ${msg}..."
        sleep 0.09; ((i++))
    done
    printf "\r  ${C_BGREEN}✓${C_RESET} ${msg}\n"
}

run_silent() {
    local desc="$1"; shift
    if [[ "${LGCL_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${C_DIM}[DRY-RUN]${C_RESET} Would execute: $*"
        echo "[DRY-RUN] $*" >> "${DRY_RUN_FILE}"
        return 0
    fi
    _log "RUN" "Executing: $*"
    "$@" >> "${LOG_FILE}" 2>&1 &
    local pid=$!
    spinner "$pid" "$desc"
    wait "$pid"
}

# =============================================================================
# SECTION 2 — GLOBAL STATE & RUNTIME CONTROL FLAGS
# =============================================================================

# Populated by CLI parser and hardware detection
declare LGCL_PROFILE="stealth"
declare LGCL_DRY_RUN="0"
declare LGCL_FORCE="0"
declare LGCL_VERBOSE="0"
declare LGCL_ACTION=""

# Hardware topology (populated by detect_hardware)
declare -i HW_RAM_GB=0
declare -i HW_CPU_CORES=0
declare -i HW_CPU_THREADS=0
declare HW_CPU_SMT="unknown"
declare HW_GPU_VENDOR="unknown"    # nvidia | amd | intel | unknown
declare HW_GPU_DRIVER="unknown"    # nouveau | nvidia | amdgpu | i915 | unknown
declare DISTRO_FAMILY=""
declare DISTRO_ID=""
declare DISTRO_CODENAME=""
declare PKG_MANAGER=""

# Snapshot ID for current transaction
declare CURRENT_SNAPSHOT_ID=""

# =============================================================================
# SECTION 3 — PROFILE DEFINITIONS
# =============================================================================
# Each profile is a declarative map of allowed operations and risk thresholds.
# Profiles are NOT bash source files — they are evaluated through controlled
# functions to prevent injection and ensure isolation.

declare -A PROFILE_STEALTH=(
    # ── Risk ceiling ──────────────────────────────────────────────────────────
    [max_risk]="SAFE"

    # ── Kernel parameters ─────────────────────────────────────────────────────
    # vm.max_map_count: SAFE — Steam itself sets this; matching Steam's value
    # is indistinguishable from a stock Steam session.
    [sysctl_vm_max_map_count]="adaptive"    # computed from RAM; capped at 1048576
    [sysctl_fs_file_max]="524288"           # SAFE — stock desktop value range
    [sysctl_fs_inotify_max_watches]="262144"
    [sysctl_vm_swappiness]="10"             # SAFE — common desktop tuning
    [sysctl_split_lock_mitigate]="SKIP"     # UNSAFE in stealth — never touch
    [sysctl_net_tuning]="SKIP"              # CAUTION — observable by AC network monitors
    [cpu_governor]="SKIP"                   # CAUTION — detectable via /sys queries

    # ── Runtime selection ─────────────────────────────────────────────────────
    [proton_variant]="official"             # official Proton only; no GE in stealth
    [dxvk_async]="0"                        # UNSAFE — async has known VAC/EAC heuristic triggers
    [esync]="1"                             # SAFE — officially supported by Proton
    [fsync]="1"                             # SAFE — kernel 5.16+ futex_waitv; Steam enables by default

    # ── Environment scope ─────────────────────────────────────────────────────
    [env_scope]="per_prefix"                # NEVER global; always per-game Wine prefix
    [wine_debug]="SKIP"                     # Do NOT set WINEDEBUG — AC may check for it
    [fsr_enabled]="0"                       # CAUTION — FSR hook modifies fullscreen behavior
    [mangohud]="0"                          # CAUTION — MangoHud injects into process space
    [gamemode]="0"                          # CAUTION — GameMode alters process priority observably

    # ── Dependency validation ─────────────────────────────────────────────────
    [validate_vulkan_icd]="1"
    [validate_32bit_stack]="1"
    [install_missing_deps]="1"
)

declare -A PROFILE_BALANCED=(
    [max_risk]="CAUTION"
    [sysctl_vm_max_map_count]="adaptive"    # computed; up to 2097152
    [sysctl_fs_file_max]="1048576"
    [sysctl_fs_inotify_max_watches]="524288"
    [sysctl_vm_swappiness]="10"
    [sysctl_split_lock_mitigate]="SKIP"     # Still skip — risk not worth it
    [sysctl_net_tuning]="conservative"      # Only TCP keepalive & rmem adjustments
    [cpu_governor]="SKIP"
    [proton_variant]="ge"                   # Proton-GE allowed with pinned version
    [dxvk_async]="0"                        # Still disabled — known ban vector
    [esync]="1"
    [fsync]="1"
    [env_scope]="per_prefix"
    [wine_debug]="-all"                     # SAFE — only suppresses log output
    [fsr_enabled]="1"                       # CAUTION — document risk
    [mangohud]="0"                          # Still off — process injection risk
    [gamemode]="1"                          # CAUTION — acceptable in non-kernel-level AC
    [validate_vulkan_icd]="1"
    [validate_32bit_stack]="1"
    [install_missing_deps]="1"
)

declare -A PROFILE_PERFORMANCE=(
    [max_risk]="UNSAFE"
    [sysctl_vm_max_map_count]="adaptive"    # computed; up to 2147483642
    [sysctl_fs_file_max]="2097152"
    [sysctl_fs_inotify_max_watches]="524288"
    [sysctl_vm_swappiness]="5"
    [sysctl_split_lock_mitigate]="0"        # UNSAFE — documents that user accepted risk
    [sysctl_net_tuning]="aggressive"
    [cpu_governor]="performance"
    [proton_variant]="ge"
    [dxvk_async]="1"                        # UNSAFE — explicit risk accepted
    [esync]="1"
    [fsync]="1"
    [env_scope]="per_prefix"
    [wine_debug]="-all"
    [fsr_enabled]="1"
    [mangohud]="1"                          # Risk accepted in performance profile
    [gamemode]="1"
    [validate_vulkan_icd]="1"
    [validate_32bit_stack]="1"
    [install_missing_deps]="1"
)

get_profile_value() {
    local profile="$1" key="$2"
    case "$profile" in
        stealth)     eval "echo \"\${PROFILE_STEALTH[$key]:-}\"" ;;
        balanced)    eval "echo \"\${PROFILE_BALANCED[$key]:-}\"" ;;
        performance) eval "echo \"\${PROFILE_PERFORMANCE[$key]:-}\"" ;;
        *)           log_fatal "Unknown profile: ${profile}" ;;
    esac
}

# =============================================================================
# SECTION 4 — HARDWARE DETECTION ENGINE
# =============================================================================

detect_hardware() {
    log_section "HARDWARE DETECTION"

    # RAM
    HW_RAM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1048576 ))
    log_ok "System RAM: ${HW_RAM_GB} GiB"

    # CPU topology
    HW_CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    HW_CPU_THREADS=$(nproc)
    if [[ "$HW_CPU_THREADS" -gt "$HW_CPU_CORES" ]]; then
        HW_CPU_SMT="enabled"
    else
        HW_CPU_SMT="disabled"
    fi
    log_ok "CPU: ${HW_CPU_CORES} cores / ${HW_CPU_THREADS} threads (SMT: ${HW_CPU_SMT})"

    # GPU vendor detection via kernel DRM subsystem (most reliable source)
    local gpu_pci_info
    gpu_pci_info="$(lspci 2>/dev/null | grep -iE '(vga|3d|display)' || true)"

    if echo "$gpu_pci_info" | grep -qi nvidia; then
        HW_GPU_VENDOR="nvidia"
        # Distinguish proprietary vs open (nouveau)
        if lsmod 2>/dev/null | grep -q '^nvidia '; then
            HW_GPU_DRIVER="nvidia"
        else
            HW_GPU_DRIVER="nouveau"
            log_warn "NVIDIA GPU with open-source Nouveau driver detected."
            log_warn "Nouveau has incomplete Vulkan support. Proprietary driver strongly recommended."
        fi
    elif echo "$gpu_pci_info" | grep -qiE '(amd|radeon|amdgpu)'; then
        HW_GPU_VENDOR="amd"
        HW_GPU_DRIVER="amdgpu"
    elif echo "$gpu_pci_info" | grep -qi intel; then
        HW_GPU_VENDOR="intel"
        HW_GPU_DRIVER="i915"
    else
        HW_GPU_VENDOR="unknown"
        HW_GPU_DRIVER="unknown"
        log_warn "Could not identify GPU vendor. Dependency installation may be incomplete."
    fi
    log_ok "GPU: vendor=${HW_GPU_VENDOR} driver=${HW_GPU_DRIVER}"

    # Distro detection
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
        case "${ID_LIKE:-$ID}" in
            *arch*)            DISTRO_FAMILY="arch";   PKG_MANAGER="pacman" ;;
            *debian*|*ubuntu*) DISTRO_FAMILY="debian"; PKG_MANAGER="apt"    ;;
            *fedora*|*rhel*)   DISTRO_FAMILY="fedora"; PKG_MANAGER="dnf"    ;;
            *)
                log_fatal "Unsupported distribution: ${ID}. Supported families: arch, debian, fedora"
                ;;
        esac
        log_ok "Distribution: ${PRETTY_NAME:-$ID} (family: ${DISTRO_FAMILY})"
    else
        log_fatal "/etc/os-release not found."
    fi
}

# =============================================================================
# SECTION 5 — ADAPTIVE SYSCTL COMPUTATION
# =============================================================================
# These functions compute values from hardware topology rather than applying
# static constants. The result is a sysctl profile that matches what a real
# machine of this spec "should" have — reducing anomaly signal to AC scanners.

compute_vm_max_map_count() {
    local profile="$1"
    local ram_gb="$HW_RAM_GB"
    local base cap result

    # Rationale: vm.max_map_count scales linearly with addressable RAM in
    # memory-intensive titles. The formula approximates what DXVK/Proton
    # actually needs at this RAM tier, capped by profile risk ceiling.
    base=$(( ram_gb * 65536 ))

    case "$profile" in
        stealth)     cap=1048576   ;;   # Stays within Steam Deck default range
        balanced)    cap=2097152   ;;   # 2x Steam Deck; safe for 16GB+ systems
        performance) cap=2147483642 ;;  # Kernel maximum
    esac

    result=$(( base < cap ? base : cap ))
    # Enforce minimum — below this, Proton itself fails
    (( result < 524288 )) && result=524288
    echo "$result"
}

compute_fs_file_max() {
    local profile="$1"
    local threads="$HW_CPU_THREADS"
    local result

    # Proportional to CPU thread count — more cores = more concurrent file ops
    # Base: 65536 per logical CPU, capped by profile
    result=$(( threads * 65536 ))
    case "$profile" in
        stealth)     (( result > 524288  )) && result=524288  ;;
        balanced)    (( result > 1048576 )) && result=1048576 ;;
        performance) (( result > 2097152 )) && result=2097152 ;;
    esac
    echo "$result"
}

# =============================================================================
# SECTION 6 — SNAPSHOT & TRANSACTION ENGINE
# =============================================================================

create_snapshot() {
    local reason="${1:-manual}"
    CURRENT_SNAPSHOT_ID="$(date +%Y%m%d-%H%M%S)-$$"
    local snap_dir="${LGCL_SNAPSHOT_DIR}/${CURRENT_SNAPSHOT_ID}"
    mkdir -p "$snap_dir"

    _log "SNAPSHOT" "Creating snapshot: ${CURRENT_SNAPSHOT_ID} (reason: ${reason})"

    # Capture current sysctl state
    sysctl -a 2>/dev/null > "${snap_dir}/sysctl.snapshot" || true

    # Capture environment.d files we may modify
    local env_target="${HOME}/.config/environment.d"
    if [[ -d "$env_target" ]]; then
        cp -r "$env_target" "${snap_dir}/environment.d.snapshot" || true
    fi

    # Capture installed sysctl drop-in files
    for f in /etc/sysctl.d/99-lgcl-*.conf /etc/security/limits.d/99-lgcl-*.conf; do
        [[ -f "$f" ]] && cp "$f" "${snap_dir}/$(basename "$f").snapshot"
    done

    # Record metadata
    cat > "${snap_dir}/metadata.json" << EOF
{
  "snapshot_id": "${CURRENT_SNAPSHOT_ID}",
  "timestamp": "$(_ts)",
  "profile": "${LGCL_PROFILE}",
  "reason": "${reason}",
  "distro_family": "${DISTRO_FAMILY}",
  "kernel": "$(uname -r)",
  "hw_ram_gb": ${HW_RAM_GB},
  "hw_gpu_vendor": "${HW_GPU_VENDOR}"
}
EOF

    echo "${CURRENT_SNAPSHOT_ID}" > "${LGCL_APPLIED_SNAPSHOT_FILE}"
    log_ok "Snapshot created: ${CURRENT_SNAPSHOT_ID}"
}

rollback_to_snapshot() {
    local snap_id="${1:-}"
    if [[ -z "$snap_id" ]]; then
        if [[ -f "${LGCL_APPLIED_SNAPSHOT_FILE}" ]]; then
            snap_id="$(cat "${LGCL_APPLIED_SNAPSHOT_FILE}")"
        else
            log_fatal "No snapshot ID specified and no applied snapshot on record."
        fi
    fi

    local snap_dir="${LGCL_SNAPSHOT_DIR}/${snap_id}"
    [[ -d "$snap_dir" ]] || log_fatal "Snapshot not found: ${snap_id} (looked in ${snap_dir})"

    log_section "ROLLBACK: ${snap_id}"

    # Restore sysctl drop-ins
    for f in "${snap_dir}"/*.conf.snapshot; do
        [[ -f "$f" ]] || continue
        local target="/etc/sysctl.d/$(basename "${f%.snapshot}")"
        if [[ -f "$f" ]]; then
            run_silent "Restoring $(basename "$target")" cp "$f" "$target"
        fi
    done

    # Re-apply sysctl
    run_silent "Re-applying sysctl state" sysctl --system

    # Restore environment.d
    if [[ -d "${snap_dir}/environment.d.snapshot" ]]; then
        local env_target="${HOME}/.config/environment.d"
        run_silent "Restoring environment.d" \
            rsync -a --delete "${snap_dir}/environment.d.snapshot/" "${env_target}/"
    else
        # Remove lgcl-injected env file if original snapshot had none
        rm -f "${HOME}/.config/environment.d/lgcl-gaming.conf"
    fi

    rm -f "${LGCL_APPLIED_SNAPSHOT_FILE}"
    log_ok "Rollback complete. All changes from snapshot ${snap_id} have been reverted."
    log_info "Reboot or re-login may be required for environment changes to take effect."
}

list_snapshots() {
    log_section "AVAILABLE SNAPSHOTS"
    local current=""
    [[ -f "${LGCL_APPLIED_SNAPSHOT_FILE}" ]] && current="$(cat "${LGCL_APPLIED_SNAPSHOT_FILE}")"

    local found=0
    for snap_dir in "${LGCL_SNAPSHOT_DIR}"/*/; do
        [[ -d "$snap_dir" ]] || continue
        local snap_id; snap_id="$(basename "$snap_dir")"
        local marker=""
        [[ "$snap_id" == "$current" ]] && marker=" ${C_BGREEN}◄ active${C_RESET}"
        local meta="${snap_dir}/metadata.json"
        if [[ -f "$meta" ]] && command -v jq &>/dev/null; then
            local ts profile reason
            ts="$(jq -r '.timestamp' "$meta")"
            profile="$(jq -r '.profile' "$meta")"
            reason="$(jq -r '.reason' "$meta")"
            echo -e "  ${C_BOLD}${snap_id}${C_RESET}${marker}"
            echo -e "    ${C_DIM}Time: ${ts} | Profile: ${profile} | Reason: ${reason}${C_RESET}"
        else
            echo -e "  ${C_BOLD}${snap_id}${C_RESET}${marker}"
        fi
        ((found++))
    done

    [[ "$found" -eq 0 ]] && echo -e "  ${C_DIM}No snapshots found in ${LGCL_SNAPSHOT_DIR}${C_RESET}"
}

# =============================================================================
# SECTION 7 — KERNEL LAYER MODULE (Profile-Gated, Adaptive)
# =============================================================================

apply_kernel_layer() {
    log_section "KERNEL LAYER — Profile: ${C_BOLD}${LGCL_PROFILE}${C_RESET}"

    [[ $EUID -ne 0 ]] && log_fatal "Kernel layer requires root. Re-run with sudo."

    local sysctl_file="/etc/sysctl.d/99-lgcl-${LGCL_PROFILE}.conf"
    local max_map_count; max_map_count="$(compute_vm_max_map_count "$LGCL_PROFILE")"
    local fs_file_max;   fs_file_max="$(compute_fs_file_max "$LGCL_PROFILE")"
    local swappiness;    swappiness="$(get_profile_value "$LGCL_PROFILE" sysctl_vm_swappiness)"
    local split_lock;    split_lock="$(get_profile_value "$LGCL_PROFILE" sysctl_split_lock_mitigate)"
    local net_tuning;    net_tuning="$(get_profile_value "$LGCL_PROFILE" sysctl_net_tuning)"

    log_info "Computed adaptive values for ${HW_RAM_GB}GiB RAM / ${HW_CPU_THREADS} threads:"
    echo -e "  vm.max_map_count = ${C_BOLD}${max_map_count}${C_RESET}"
    echo -e "  fs.file-max      = ${C_BOLD}${fs_file_max}${C_RESET}"
    echo ""

    # Build the sysctl file content
    local content
    content="# LGCL — Kernel Parameters (Profile: ${LGCL_PROFILE})
# Generated: $(_ts) | Hardware: ${HW_RAM_GB}GiB RAM, ${HW_CPU_THREADS} threads, GPU: ${HW_GPU_VENDOR}
# DO NOT EDIT MANUALLY — managed by lgcl. Use: lgcl --rollback to undo.
"

    # --- vm.max_map_count ---------------------------------------------------
    # RISK: SAFE in stealth/balanced. This parameter is set by the Steam client
    # itself on launch. Our value matches what Steam would set for this RAM tier.
    # The range [524288, 1048576] is indistinguishable from Steam's own writes.
    log_risk "SAFE" "vm.max_map_count=${max_map_count}" \
        "Matches Steam client's own write pattern for ${HW_RAM_GB}GiB systems"
    content+="vm.max_map_count = ${max_map_count}
"

    # --- fs.file-max --------------------------------------------------------
    log_risk "SAFE" "fs.file-max=${fs_file_max}" \
        "Standard desktop tuning; not observable by game-level AC"
    content+="fs.file-max = ${fs_file_max}
fs.inotify.max_user_watches = $(get_profile_value "$LGCL_PROFILE" sysctl_fs_inotify_max_watches)
fs.inotify.max_user_instances = 1024
fs.inotify.max_queued_events = 32768
"

    # --- vm.swappiness -------------------------------------------------------
    log_risk "SAFE" "vm.swappiness=${swappiness}" \
        "Common desktop setting; below detection threshold of game-level scanners"
    content+="vm.swappiness = ${swappiness}
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
"

    # --- split_lock_mitigate ------------------------------------------------
    if [[ "$split_lock" == "SKIP" ]]; then
        log_risk "CAUTION" "split_lock_mitigate: SKIPPED (profile: ${LGCL_PROFILE})" \
            "Kernel-level change; detectable via /proc; only enabled in performance profile"
    else
        log_risk "UNSAFE" "split_lock_mitigate=${split_lock}" \
            "Modifies kernel fault behavior; detectable by kernel-mode AC. Performance profile only."
        content+="kernel.split_lock_mitigate = ${split_lock}
"
    fi

    # --- network tuning -----------------------------------------------------
    case "$net_tuning" in
        conservative)
            log_risk "CAUTION" "Network: conservative tuning (TCP keepalive only)" \
                "Keepalive changes are below AC network inspection threshold"
            content+="net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
"
            ;;
        aggressive)
            log_risk "UNSAFE" "Network: aggressive tuning enabled" \
                "Buffer sizes and TCP behavior changes may be fingerprinted by server-side AC"
            content+="net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
"
            ;;
        SKIP)
            log_info "Network tuning: skipped (profile: ${LGCL_PROFILE})"
            ;;
    esac

    # --- shared memory (Wine/Proton IPC) -----------------------------------
    # Scaled to RAM; below 16GiB defaults to 8GiB shmmax
    local shmmax=$(( HW_RAM_GB >= 16 ? 17179869184 : 8589934592 ))
    content+="kernel.shmmax = ${shmmax}
kernel.shmall = $(( shmmax / 4096 ))
"

    # Write sysctl file
    if [[ "${LGCL_DRY_RUN}" == "1" ]]; then
        echo -e "  ${C_DIM}[DRY-RUN] Would write to ${sysctl_file}:${C_RESET}"
        echo "$content" | sed 's/^/    /'
    else
        echo "$content" > "$sysctl_file"
        run_silent "Applying sysctl parameters" sysctl --system
        _validate_sysctl_applied "$max_map_count" "$fs_file_max"
    fi

    # --- PAM limits ----------------------------------------------------------
    _apply_pam_limits

    # --- CPU governor (performance profile only) ----------------------------
    local cpu_gov; cpu_gov="$(get_profile_value "$LGCL_PROFILE" cpu_governor)"
    if [[ "$cpu_gov" != "SKIP" ]]; then
        log_risk "CAUTION" "CPU governor → ${cpu_gov}" \
            "Observable via /sys/devices/system/cpu; AC kernel modules can query this"
        _apply_cpu_governor "$cpu_gov"
    fi

    # --- Transparent Huge Pages (THP) ---------------------------------------
    # madvise is always correct here: allows DXVK/VKD3D shader memory to
    # opt into huge pages while preventing THP from aggressively promoting
    # unrelated allocations that AC might scan.
    _apply_thp_policy "madvise"

    log_ok "Kernel layer applied (profile: ${LGCL_PROFILE})"
}

_validate_sysctl_applied() {
    local expected_map_count="$1"
    local expected_file_max="$2"

    local actual_map; actual_map="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    local actual_file; actual_file="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"

    if [[ "$actual_map" != "$expected_map_count" ]]; then
        log_warn "vm.max_map_count mismatch: expected=${expected_map_count} actual=${actual_map}"
        log_warn "Another sysctl file may be overriding. Check: sysctl -a | grep max_map_count"
    else
        log_ok "Validated: vm.max_map_count = ${actual_map}"
    fi

    if [[ "$actual_file" != "$expected_file_max" ]]; then
        log_warn "fs.file-max mismatch: expected=${expected_file_max} actual=${actual_file}"
    else
        log_ok "Validated: fs.file-max = ${actual_file}"
    fi
}

_apply_pam_limits() {
    local limits_file="/etc/security/limits.d/99-lgcl-${LGCL_PROFILE}.conf"
    cat > "$limits_file" << EOF
# LGCL PAM Limits — Profile: ${LGCL_PROFILE}
# Generated: $(_ts)
*    soft    nofile    $(( HW_CPU_THREADS * 65536 < 1048576 ? 1048576 : HW_CPU_THREADS * 65536 ))
*    hard    nofile    $(( HW_CPU_THREADS * 65536 < 1048576 ? 1048576 : HW_CPU_THREADS * 65536 ))
*    soft    nproc     65536
*    hard    nproc     65536
*    soft    memlock   unlimited
*    hard    memlock   unlimited
EOF
    log_ok "PAM limits written: ${limits_file}"
}

_apply_cpu_governor() {
    local gov="$1"
    if command -v cpupower &>/dev/null; then
        run_silent "Setting CPU governor: ${gov}" cpupower frequency-set -g "$gov"
    else
        local path
        for path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [[ -w "$path" ]] && echo "$gov" > "$path"
        done
        log_ok "CPU governor set to ${gov} via sysfs"
    fi
}

_apply_thp_policy() {
    local policy="$1"
    local thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
    local thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"
    if [[ -f "$thp_enabled" ]]; then
        echo "$policy" > "$thp_enabled"
        # 'defer+madvise' defrag mode: only defrag on explicit madvise, defer otherwise
        if grep -q 'defer+madvise' "$thp_defrag" 2>/dev/null; then
            echo "defer+madvise" > "$thp_defrag"
        else
            echo "madvise" > "$thp_defrag"
        fi
        log_ok "THP policy: enabled=${policy}, defrag=defer+madvise"
    fi
}

# =============================================================================
# SECTION 8 — RUNTIME MODULE (Version-Pinned, Integrity-Verified)
# =============================================================================

apply_runtime_module() {
    log_section "RUNTIME MODULE — Profile: ${C_BOLD}${LGCL_PROFILE}${C_RESET}"

    local proton_variant; proton_variant="$(get_profile_value "$LGCL_PROFILE" proton_variant)"

    case "$proton_variant" in
        official)
            log_info "Profile '${LGCL_PROFILE}' uses official Proton only."
            log_risk "SAFE" "Official Proton runtime" \
                "Steam-managed; indistinguishable from stock install; no AC fingerprint risk"
            _verify_steam_official_proton
            ;;
        ge)
            log_risk "CAUTION" "Proton-GE runtime" \
                "Modified Wine+Proton build; versioning differs from Steam's. EAC/BattlEye check runtime path, not binary content."
            _install_proton_ge_verified
            ;;
    esac

    _verify_ac_runtimes
}

_verify_steam_official_proton() {
    # Detect all installed official Proton versions via Steam's VDF manifest
    local steam_apps="${HOME}/.steam/steam/steamapps"
    local proton_found=0

    if [[ -d "$steam_apps" ]]; then
        local manifest
        while IFS= read -r manifest; do
            local name; name="$(grep -oP '"name"\s+"\K[^"]+' "$manifest" 2>/dev/null | head -1)"
            if [[ "$name" =~ ^Proton\ [0-9] ]]; then
                log_ok "Official Proton detected: ${name}"
                ((proton_found++))
            fi
        done < <(find "$steam_apps" -name 'appmanifest_*.acf' 2>/dev/null)
    fi

    if [[ "$proton_found" -eq 0 ]]; then
        log_warn "No official Proton installation found."
        log_warn "In Steam: Settings → Compatibility → Enable Steam Play, then download a Proton version."
    fi
}

_install_proton_ge_verified() {
    command -v curl &>/dev/null || log_fatal "curl required for Proton-GE download"
    command -v sha512sum &>/dev/null || log_fatal "sha512sum required for integrity verification"

    # Enforce version pinning: never silently update to "latest"
    local pinfile="${LGCL_STATE_DIR}/proton_ge_pinned_version"
    local version=""

    if [[ -f "$pinfile" ]] && [[ "${LGCL_FORCE}" != "1" ]]; then
        version="$(cat "$pinfile")"
        log_info "Using pinned Proton-GE version: ${version} (use --force to update)"
    else
        log_info "Fetching latest Proton-GE release metadata from GitHub..."
        local api_response
        api_response="$(curl -fsSL --max-time 15 \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest" \
            2>/dev/null)" || log_fatal "GitHub API unreachable. Check network connectivity."

        # Use jq if available for reliable JSON parsing; fall back to grep with strict pattern
        if command -v jq &>/dev/null; then
            version="$(echo "$api_response" | jq -r '.tag_name')"
        else
            version="$(echo "$api_response" | grep -oP '"tag_name":\s*"GE-Proton\K[^"]+' | head -1)"
            [[ -n "$version" ]] && version="GE-Proton${version}"
        fi

        [[ -z "$version" || "$version" == "null" ]] && \
            log_fatal "Failed to parse Proton-GE version. API response: ${api_response:0:200}"

        log_ok "Latest Proton-GE: ${version}"
        echo "$version" > "$pinfile"
    fi

    local target_dir="${STEAM_COMPAT_DIR}/${version}"
    if [[ -d "$target_dir" ]] && [[ "${LGCL_FORCE}" != "1" ]]; then
        log_ok "Proton-GE ${version} already installed at ${target_dir}"
        return 0
    fi

    # Fetch release asset URLs (tarball + checksum)
    local api_response
    api_response="$(curl -fsSL --max-time 15 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/tags/${version}" \
        2>/dev/null)"

    local tarball_url sha512_url
    if command -v jq &>/dev/null; then
        tarball_url="$(echo "$api_response" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')"
        sha512_url="$(echo  "$api_response" | jq -r '.assets[] | select(.name | endswith(".sha512sum")) | .browser_download_url')"
    else
        tarball_url="$(echo "$api_response" | grep -oP '"browser_download_url":\s*"\K[^"]+\.tar\.gz' | head -1)"
        sha512_url="$(echo  "$api_response" | grep -oP '"browser_download_url":\s*"\K[^"]+\.sha512sum' | head -1)"
    fi

    [[ -z "$tarball_url" ]] && log_fatal "Could not extract tarball URL for ${version}"
    [[ -z "$sha512_url"  ]] && log_fatal "Could not extract SHA512 URL for ${version}"

    local work_dir; work_dir="$(mktemp -d)"
    local tarball="${work_dir}/${version}.tar.gz"
    local sha512file="${work_dir}/${version}.sha512sum"

    log_info "Downloading Proton-GE ${version}..."
    curl -fSL --progress-bar -o "$tarball"   "$tarball_url" || log_fatal "Download failed: ${tarball_url}"
    curl -fsSL               -o "$sha512file" "$sha512_url"  || log_fatal "Download failed: ${sha512_url}"

    # --- Integrity verification (SHA512) ------------------------------------
    log_info "Verifying SHA512 integrity..."
    local expected_hash; expected_hash="$(awk '{print $1}' "$sha512file")"
    local actual_hash;   actual_hash="$(sha512sum "$tarball" | awk '{print $1}')"

    if [[ "$expected_hash" != "$actual_hash" ]]; then
        rm -rf "$work_dir"
        log_fatal "SHA512 MISMATCH for ${version}. File may be corrupted or tampered. Aborting."
    fi
    log_ok "SHA512 integrity verified"

    mkdir -p "${STEAM_COMPAT_DIR}"
    run_silent "Extracting ${version}" tar -xzf "$tarball" -C "${STEAM_COMPAT_DIR}"
    rm -rf "$work_dir"

    log_ok "Proton-GE ${version} installed: ${target_dir}"
}

_verify_ac_runtimes() {
    # Anti-cheat runtimes are managed exclusively by Steam.
    # We verify their presence but do NOT create, modify, or symlink them.
    # Creating manual symlinks was a valid approach pre-2022; as of Proton 7.0+,
    # Steam manages these paths internally and the correct method is to
    # enable them per-game in Steam settings.
    log_info "Verifying Steam-managed anti-cheat runtimes..."

    local eac_path="${STEAM_RUNTIME_DIR}/${EAC_RUNTIME_NAME}"
    local be_path="${STEAM_RUNTIME_DIR}/${BATTLEYE_RUNTIME_NAME}"

    if [[ -d "$eac_path" ]]; then
        log_ok "EAC runtime present (Steam-managed): ${eac_path}"
        log_risk "SAFE" "EAC runtime: Steam-managed path" \
            "Not symlinked or modified; indistinguishable from standard Steam install"
    else
        log_warn "EAC runtime not found at expected path: ${eac_path}"
        log_warn "To install: In Steam, right-click a EAC game → Properties → Local Files → Verify"
        log_warn "Or install AppID ${PROTON_APPID_EAC} via steamcmd"
    fi

    if [[ -d "$be_path" ]]; then
        log_ok "BattlEye runtime present (Steam-managed): ${be_path}"
        log_risk "SAFE" "BattlEye runtime: Steam-managed path" \
            "Not symlinked or modified; matches Steam runtime expectations"
    else
        log_warn "BattlEye runtime not found at: ${be_path}"
        log_warn "Install AppID ${PROTON_APPID_BATTLEYE} via steamcmd or Steam UI"
    fi
}

# =============================================================================
# SECTION 9 — DEPENDENCY FORTRESS MODULE (Distro-Aware, GPU-Aware)
# =============================================================================

apply_dependency_module() {
    log_section "DEPENDENCY FORTRESS — ${DISTRO_FAMILY} / GPU: ${HW_GPU_VENDOR}"

    [[ $EUID -ne 0 ]] && log_fatal "Dependency installation requires root."

    case "$DISTRO_FAMILY" in
        arch)   _deps_arch   ;;
        debian) _deps_debian ;;
        fedora) _deps_fedora ;;
    esac

    _validate_vulkan_icd
    _detect_conflicting_drivers
}

# Common package lists (logical groups, not raw names)
_deps_arch() {
    # Enable multilib if absent (required for all 32-bit packages)
    if ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
        log_info "Enabling [multilib] repository..."
        sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' /etc/pacman.conf
        run_silent "Syncing pacman databases" pacman -Sy --noconfirm
    fi

    local pkgs=(
        vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools
        mesa lib32-mesa mesa-vdpau
        shaderc spirv-tools glslang
        sdl2 lib32-sdl2
        libx11 lib32-libx11 libxcomposite lib32-libxcomposite libxrandr
        pipewire pipewire-pulse wireplumber lib32-pipewire
        python curl wget jq cabextract unzip p7zip
        steam-native-runtime
    )

    # GPU-specific additions
    case "$HW_GPU_VENDOR" in
        nvidia)
            pkgs+=(
                vulkan-validation-layers lib32-vulkan-validation-layers
            )
            if [[ "$HW_GPU_DRIVER" == "nvidia" ]]; then
                pkgs+=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings opencl-nvidia lib32-opencl-nvidia)
            else
                log_warn "Nouveau driver detected. Installing mesa Vulkan only — Nouveau has no Vulkan via proprietary path."
            fi
            ;;
        amd)
            pkgs+=(vulkan-radeon lib32-vulkan-radeon libdrm lib32-libdrm amdvlk lib32-amdvlk)
            ;;
        intel)
            pkgs+=(vulkan-intel lib32-vulkan-intel)
            ;;
    esac

    run_silent "Installing Arch dependency stack (${#pkgs[@]} packages)" \
        pacman -S --noconfirm --needed "${pkgs[@]}"

    log_ok "Arch dependency stack installed"
}

_deps_debian() {
    if ! dpkg --print-foreign-architectures | grep -q i386; then
        run_silent "Enabling i386 multiarch" dpkg --add-architecture i386
    fi

    # Wine repo for proper staging builds
    if [[ ! -f /etc/apt/keyrings/winehq.gpg ]]; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
            | gpg --dearmor -o /etc/apt/keyrings/winehq.gpg
        local cn="${DISTRO_CODENAME}"
        echo "deb [signed-by=/etc/apt/keyrings/winehq.gpg] https://dl.winehq.org/wine-builds/ubuntu/ ${cn} main" \
            > /etc/apt/sources.list.d/winehq.list
    fi

    run_silent "Updating apt index" apt-get update -q

    local pkgs=(
        libvulkan1 libvulkan1:i386 vulkan-tools
        mesa-vulkan-drivers mesa-vulkan-drivers:i386
        libgl1-mesa-dri libgl1-mesa-dri:i386
        libsdl2-2.0-0 libsdl2-2.0-0:i386
        libgnutls30 libgnutls30:i386
        libdbus-1-3 libdbus-1-3:i386
        pipewire pipewire-pulse wireplumber
        glslang-tools spirv-tools
        jq curl wget cabextract unzip p7zip-full python3
    )

    case "$HW_GPU_VENDOR" in
        nvidia)
            if [[ "$HW_GPU_DRIVER" == "nvidia" ]]; then
                pkgs+=(nvidia-driver nvidia-opencl-icd)
            fi
            ;;
        amd)
            pkgs+=(xserver-xorg-video-amdgpu mesa-opencl-icd)
            ;;
    esac

    run_silent "Installing Debian dependency stack" apt-get install -y --no-install-recommends "${pkgs[@]}"
    log_ok "Debian dependency stack installed"
}

_deps_fedora() {
    # RPM Fusion required for multimedia/gaming stack
    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        run_silent "Enabling RPM Fusion Free" \
            dnf install -y "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    fi
    if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        run_silent "Enabling RPM Fusion NonFree" \
            dnf install -y "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
    fi

    local pkgs=(
        vulkan vulkan-tools vulkan-loader vulkan-loader.i686
        mesa-libGL mesa-libGL.i686 mesa-dri-drivers mesa-dri-drivers.i686
        mesa-vulkan-drivers mesa-vulkan-drivers.i686
        SDL2 SDL2.i686
        pipewire pipewire-pulseaudio wireplumber
        glslang spirv-tools
        jq curl wget cabextract unzip p7zip python3
    )

    case "$HW_GPU_VENDOR" in
        nvidia)
            [[ "$HW_GPU_DRIVER" == "nvidia" ]] && \
                pkgs+=(akmod-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-libs xorg-x11-drv-nvidia-libs.i686)
            ;;
        amd)
            pkgs+=(mesa-va-drivers mesa-va-drivers.i686)
            ;;
    esac

    run_silent "Installing Fedora dependency stack" dnf install -y "${pkgs[@]}"
    log_ok "Fedora dependency stack installed"
}

_validate_vulkan_icd() {
    log_info "Validating active Vulkan ICD configuration..."

    # Check for ICD JSON files — their presence indicates driver registration
    local icd_dir="/usr/share/vulkan/icd.d"
    local icd_files; icd_files="$(find "$icd_dir" -name '*.json' 2>/dev/null | sort)"

    if [[ -z "$icd_files" ]]; then
        log_warn "No Vulkan ICD files found in ${icd_dir}"
        return 1
    fi

    while IFS= read -r icd; do
        local name; name="$(basename "$icd")"
        # Validate JSON structure if jq is available
        if command -v jq &>/dev/null; then
            if jq -e '.ICD.library_path' "$icd" &>/dev/null; then
                local lib; lib="$(jq -r '.ICD.library_path' "$icd")"
                if [[ -f "$lib" ]]; then
                    log_ok "ICD: ${name} → ${lib} (library present)"
                else
                    log_warn "ICD: ${name} references missing library: ${lib}"
                fi
            else
                log_warn "ICD: ${name} has malformed JSON structure"
            fi
        else
            log_ok "ICD found: ${name} (install jq for deep validation)"
        fi
    done <<< "$icd_files"
}

_detect_conflicting_drivers() {
    log_info "Checking for conflicting GPU driver installations..."

    if [[ "$HW_GPU_VENDOR" == "nvidia" ]] && [[ "$HW_GPU_DRIVER" == "nvidia" ]]; then
        # Detect nouveau + nvidia co-existence (common post-driver-install issue)
        if lsmod 2>/dev/null | grep -q '^nouveau '; then
            log_warn "Conflict detected: nouveau module loaded alongside proprietary NVIDIA driver"
            log_warn "Remediation: echo 'blacklist nouveau' > /etc/modprobe.d/blacklist-nouveau.conf && update-initramfs -u"
        fi
    fi

    # Detect AMDVLK vs RADV co-existence (can cause unexpected ICD selection)
    if [[ "$HW_GPU_VENDOR" == "amd" ]]; then
        local has_amdvlk=0 has_radv=0
        find /usr/share/vulkan/icd.d -name 'amd_icd*.json'   &>/dev/null && has_amdvlk=1
        find /usr/share/vulkan/icd.d -name 'radeon_icd*.json' &>/dev/null && has_radv=1

        if [[ "$has_amdvlk" -eq 1 ]] && [[ "$has_radv" -eq 1 ]]; then
            log_warn "Both AMDVLK and RADV ICD files present."
            log_warn "RADV (Mesa) is recommended for Proton/DXVK. Set: AMD_VULKAN_ICD=RADV in per-game launch options."
            log_warn "AMDVLK has known compatibility issues with some DXVK builds."
        fi
    fi

    log_ok "Driver conflict check complete"
}

# =============================================================================
# SECTION 10 — ENVIRONMENT ISOLATION MODULE
# =============================================================================
# Critical design: NO global /etc/environment.d injection.
# All variables are scoped to a per-game Steam launch wrapper template.
# This prevents AC systems from observing WINE_* or DXVK_* in ambient env.

apply_environment_module() {
    log_section "ENVIRONMENT ISOLATION — Profile: ${C_BOLD}${LGCL_PROFILE}${C_RESET}"

    local dxvk_async;   dxvk_async="$(get_profile_value   "$LGCL_PROFILE" dxvk_async)"
    local esync;        esync="$(get_profile_value         "$LGCL_PROFILE" esync)"
    local fsync;        fsync="$(get_profile_value         "$LGCL_PROFILE" fsync)"
    local wine_debug;   wine_debug="$(get_profile_value    "$LGCL_PROFILE" wine_debug)"
    local fsr_enabled;  fsr_enabled="$(get_profile_value   "$LGCL_PROFILE" fsr_enabled)"
    local mangohud;     mangohud="$(get_profile_value      "$LGCL_PROFILE" mangohud)"
    local gamemode_en;  gamemode_en="$(get_profile_value   "$LGCL_PROFILE" gamemode)"
    local env_scope;    env_scope="$(get_profile_value     "$LGCL_PROFILE" env_scope)"

    log_info "Environment scope: ${C_BOLD}${env_scope}${C_RESET}"
    log_info "Generating Steam launch option templates and per-prefix configs..."

    # --- Risk analysis display ----------------------------------------------
    echo ""
    echo -e "  ${C_BOLD}Risk Analysis for Profile: ${LGCL_PROFILE}${C_RESET}"
    echo -e "  $(printf '─%.0s' $(seq 1 60))"

    if [[ "$dxvk_async" == "1" ]]; then
        log_risk "UNSAFE" "DXVK_ASYNC=1" \
            "Async pipeline compilation bypasses shader validation timing; EAC heuristics flag this in some titles (notably EAC kernel-mode games). Disabled in stealth/balanced."
    else
        log_risk "SAFE" "DXVK_ASYNC=0 (disabled)" \
            "Synchronous shader compilation matches Proton default behavior"
    fi

    if [[ "$esync" == "1" ]]; then
        log_risk "SAFE" "PROTON_NO_ESYNC=0 (esync enabled)" \
            "esync is enabled by default in official Proton; behavior is identical"
    fi

    if [[ "$fsync" == "1" ]]; then
        log_risk "SAFE" "PROTON_NO_FSYNC=0 (fsync enabled)" \
            "futex_waitv-based sync; enabled by default in Steam Deck runtime"
    fi

    if [[ "$fsr_enabled" == "1" ]]; then
        log_risk "CAUTION" "WINE_FULLSCREEN_FSR=1" \
            "Modifies fullscreen window behavior via Wine hook; not observable at kernel level but alters GPU present chain timing"
    fi

    if [[ "$mangohud" == "1" ]]; then
        log_risk "CAUTION" "MangoHud injection enabled" \
            "Uses LD_PRELOAD to inject into game process; kernel-mode AC (EAC/BattlEye) can detect injected libraries"
    fi

    if [[ "$gamemode_en" == "1" ]]; then
        log_risk "CAUTION" "GameMode enabled" \
            "gamemoded alters process scheduler priority; observable via /proc but generally tolerated by userspace AC"
    fi

    if [[ "$wine_debug" == "SKIP" ]]; then
        log_risk "SAFE" "WINEDEBUG: not set" \
            "Some AC systems check for WINEDEBUG in environment as a debugging/cheat indicator"
    fi

    echo ""

    # --- Generate Steam launch option string --------------------------------
    _generate_steam_launch_template

    # --- Write per-user prefix config (NOT global) --------------------------
    _write_prefix_environment_config

    log_ok "Environment module complete (scope: ${env_scope})"
}

_generate_steam_launch_template() {
    local template_file="${LGCL_HOME}/steam_launch_options_${LGCL_PROFILE}.txt"

    local proton_var; proton_var="$(get_profile_value "$LGCL_PROFILE" proton_variant)"
    local dxvk_async; dxvk_async="$(get_profile_value "$LGCL_PROFILE" dxvk_async)"
    local fsr;        fsr="$(get_profile_value "$LGCL_PROFILE" fsr_enabled)"
    local mangohud;   mangohud="$(get_profile_value "$LGCL_PROFILE" mangohud)"
    local gamemode_en;gamemode_en="$(get_profile_value "$LGCL_PROFILE" gamemode)"
    local esync;      esync="$(get_profile_value "$LGCL_PROFILE" esync)"
    local fsync;      fsync="$(get_profile_value "$LGCL_PROFILE" fsync)"
    local wine_debug; wine_debug="$(get_profile_value "$LGCL_PROFILE" wine_debug)"

    local launch_opts=""

    # GameMode prefix (runs gamemoderun wrapper)
    [[ "$gamemode_en" == "1" ]] && launch_opts+="gamemoderun "

    # MangoHud prefix
    [[ "$mangohud" == "1" ]] && launch_opts+="mangohud "

    # Environment variable injection (per-invocation, not global)
    [[ "$dxvk_async" == "1" ]] && launch_opts+="DXVK_ASYNC=1 "
    [[ "$dxvk_async" == "0" ]] && launch_opts+="DXVK_ASYNC=0 "
    [[ "$fsr" == "1" ]]        && launch_opts+="WINE_FULLSCREEN_FSR=1 WINE_FULLSCREEN_FSR_STRENGTH=2 "
    [[ "$fsync" == "1" ]]      && launch_opts+="PROTON_NO_FSYNC=0 "
    [[ "$esync" == "1" ]]      && launch_opts+="PROTON_NO_ESYNC=0 "
    [[ "$wine_debug" != "SKIP" ]] && launch_opts+="WINEDEBUG=${wine_debug} "

    # Required for EAC/BattlEye — must always be set in launch options
    launch_opts+="PROTON_EAC_RUNTIME=\${HOME}/.steam/steam/steamapps/common/Proton\\ EasyAntiCheat\\ Runtime "
    launch_opts+="PROTON_BATTLEYE_RUNTIME=\${HOME}/.steam/steam/steamapps/common/Proton\\ BattlEye\\ Runtime "

    # The %command% token — always last
    launch_opts+="%command%"

    cat > "$template_file" << EOF
# ============================================================
# LGCL Steam Launch Options Template — Profile: ${LGCL_PROFILE}
# Generated: $(_ts)
# ============================================================
# Paste the following line into:
#   Steam → Right-click game → Properties → General → Launch Options
#
# IMPORTANT: These variables are scoped to the game process only.
# They are NOT set globally in your shell or system environment.
# ============================================================

${launch_opts}

# ── Risk notes ────────────────────────────────────────────────────────────────
# Profile '${LGCL_PROFILE}' risk ceiling: $(get_profile_value "$LGCL_PROFILE" max_risk)
$(if [[ "$(get_profile_value "$LGCL_PROFILE" dxvk_async)" == "1" ]]; then
    echo "# WARNING: DXVK_ASYNC=1 is present. Risk: UNSAFE for kernel-mode EAC titles."
    echo "#          Remove for: Destiny 2, Rust, EFT, or any EAC Easy Anti-Cheat kernel title."
fi)
# For Proton variant: $(get_profile_value "$LGCL_PROFILE" proton_variant)
EOF

    log_ok "Steam launch template written: ${template_file}"
    echo ""
    echo -e "  ${C_BOLD}Copy this into Steam Launch Options:${C_RESET}"
    echo -e "  ${C_CYAN}${launch_opts}${C_RESET}"
    echo ""
}

_write_prefix_environment_config() {
    # Write to ~/.config/environment.d/ — this is the XDG-correct location
    # for user-session environment variables. It is NOT /etc/environment.d/
    # and does NOT affect system services or root processes.
    # Note: This still affects the whole user session, so we are CONSERVATIVE
    # about what goes here — only values that cannot cause AC false positives.
    local env_dir="${HOME}/.config/environment.d"
    mkdir -p "$env_dir"
    local env_file="${env_dir}/lgcl-gaming.conf"

    cat > "$env_file" << EOF
# LGCL User Environment — Profile: ${LGCL_PROFILE}
# Generated: $(_ts)
# Scope: User session only (NOT system-wide)
# DO NOT add DXVK_ASYNC, WINEDEBUG, or LD_PRELOAD here.
# Those belong in per-game Steam launch options only.

# Mesa shader cache — SAFE, not observable by AC
MESA_SHADER_CACHE_MAX_SIZE=10G

# Steam Play / Proton — these are read by Steam, not by game processes directly
STEAM_COMPAT_MOUNTS=/run/media

# SDL video driver — set to x11 for maximum compatibility
# Override in per-game launch options if using Wayland
SDL_VIDEODRIVER=x11
EOF

    log_ok "User session environment written: ${env_file}"
    log_warn "Variables that carry AC risk (DXVK_ASYNC, WINEDEBUG, LD_PRELOAD) are"
    log_warn "intentionally NOT written here. Use the Steam launch template instead."
}

# =============================================================================
# SECTION 11 — DIAGNOSTICS ENGINE (Stateless, Confidence-Scored)
# =============================================================================

run_diagnostics() {
    log_section "LGCL DIAGNOSTICS ENGINE"

    local -i score=0
    local -i max_score=0
    local -a issues=()
    local -a remediation=()

    _diag_check() {
        local label="$1" result="$2" weight="${3:-1}" fix="${4:-}"
        ((max_score += weight))
        if [[ "$result" == "pass" ]]; then
            echo -e "  ${C_BGREEN}✓${C_RESET} [+${weight}] ${label}"
            ((score += weight))
        elif [[ "$result" == "warn" ]]; then
            echo -e "  ${C_BYELLOW}⚠${C_RESET} [ 0] ${label}"
            issues+=("$label")
            [[ -n "$fix" ]] && remediation+=("$fix")
        else
            echo -e "  ${C_BRED}✗${C_RESET} [ 0] ${label}"
            issues+=("FAIL: $label")
            [[ -n "$fix" ]] && remediation+=("REQUIRED: $fix")
        fi
    }

    # ── Kernel Parameters ─────────────────────────────────────────────────────
    echo -e "\n  ${C_BOLD}Kernel Parameters${C_RESET}"
    local max_map; max_map="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    [[ "$max_map" -ge 524288 ]] \
        && _diag_check "vm.max_map_count ≥ 524288 (current: ${max_map})" "pass" 3 \
        || _diag_check "vm.max_map_count ≥ 524288 (current: ${max_map})" "fail" 3 \
                       "Run: lgcl --profile stealth --apply"

    local file_max; file_max="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
    [[ "$file_max" -ge 524288 ]] \
        && _diag_check "fs.file-max ≥ 524288 (current: ${file_max})" "pass" 2 \
        || _diag_check "fs.file-max ≥ 524288 (current: ${file_max})" "warn" 2 \
                       "Run: lgcl --profile stealth --apply"

    local split_lock; split_lock="$(sysctl -n kernel.split_lock_mitigate 2>/dev/null || echo 'n/a')"
    if [[ "$split_lock" == "0" ]]; then
        _diag_check "split_lock_mitigate=0 (UNSAFE: performance profile only)" "warn" 0 \
                    "If using EAC kernel-mode games, set kernel.split_lock_mitigate=1"
    else
        _diag_check "split_lock_mitigate=${split_lock} (safe for AC)" "pass" 1
    fi

    # ── Steam & Proton ────────────────────────────────────────────────────────
    echo -e "\n  ${C_BOLD}Steam & Proton${C_RESET}"
    [[ -d "${STEAM_ROOT}" ]] \
        && _diag_check "Steam root exists: ${STEAM_ROOT}" "pass" 2 \
        || _diag_check "Steam root not found: ${STEAM_ROOT}" "fail" 2 \
                       "Install Steam via your package manager"

    local proton_count; proton_count="$(find "${STEAM_RUNTIME_DIR}" -maxdepth 1 -name 'Proton [0-9]*' -type d 2>/dev/null | wc -l)"
    [[ "$proton_count" -gt 0 ]] \
        && _diag_check "Official Proton versions: ${proton_count}" "pass" 3 \
        || _diag_check "No official Proton found" "fail" 3 \
                       "In Steam: Settings → Compatibility → Enable Steam Play → Download Proton"

    local ge_count; ge_count="$(find "${STEAM_COMPAT_DIR}" -maxdepth 1 -name 'GE-Proton*' -type d 2>/dev/null | wc -l)"
    if [[ "$ge_count" -gt 0 ]]; then
        _diag_check "Proton-GE installations: ${ge_count}" "pass" 1
    else
        _diag_check "Proton-GE: not installed (optional, balanced/performance only)" "warn" 0 \
                    "Run: lgcl --profile balanced --apply"
    fi

    # ── Anti-Cheat Runtimes ───────────────────────────────────────────────────
    echo -e "\n  ${C_BOLD}Anti-Cheat Runtimes${C_RESET}"
    local eac_path="${STEAM_RUNTIME_DIR}/${EAC_RUNTIME_NAME}"
    [[ -d "$eac_path" ]] \
        && _diag_check "EAC runtime present (Steam-managed)" "pass" 3 \
        || _diag_check "EAC runtime missing: ${eac_path}" "warn" 3 \
                       "In Steam: download AppID ${PROTON_APPID_EAC} or verify an EAC game"

    local be_path="${STEAM_RUNTIME_DIR}/${BATTLEYE_RUNTIME_NAME}"
    [[ -d "$be_path" ]] \
        && _diag_check "BattlEye runtime present (Steam-managed)" "pass" 3 \
        || _diag_check "BattlEye runtime missing: ${be_path}" "warn" 3 \
                       "In Steam: download AppID ${PROTON_APPID_BATTLEYE} or verify a BattlEye game"

    # Detect broken/manual symlinks (these ARE an AC detection risk)
    for rt_path in "$eac_path" "$be_path"; do
        if [[ -L "$rt_path" ]]; then
            _diag_check "$(basename "$rt_path") is a symlink — RISK" "warn" 0 \
                        "Remove symlink and let Steam manage: rm -f '${rt_path}' && steam-verify-game"
        fi
    done

    # ── Vulkan ────────────────────────────────────────────────────────────────
    echo -e "\n  ${C_BOLD}Vulkan Driver Stack${C_RESET}"
    if command -v vulkaninfo &>/dev/null; then
        local vk_gpus; vk_gpus="$(vulkaninfo 2>/dev/null | grep -c 'GPU id' || echo 0)"
        [[ "$vk_gpus" -gt 0 ]] \
            && _diag_check "Vulkan GPU count: ${vk_gpus}" "pass" 3 \
            || _diag_check "No Vulkan-capable GPU detected" "fail" 3 \
                           "Install GPU drivers: lgcl --apply (handles driver installation)"
    else
        _diag_check "vulkaninfo binary missing" "warn" 1 \
                    "Install vulkan-tools (Arch/Debian) or vulkan-tools (Fedora)"
    fi

    # 32-bit Vulkan ICD
    local icd_32; icd_32="$(find /usr/share/vulkan/icd.d -name '*i686*' -o -name '*x86*' 2>/dev/null | head -1)"
    [[ -n "$icd_32" ]] \
        && _diag_check "32-bit Vulkan ICD found: $(basename "$icd_32")" "pass" 2 \
        || _diag_check "32-bit Vulkan ICD missing" "warn" 2 \
                       "Run: lgcl --apply (installs 32-bit Vulkan stack)"

    # ── Environment Hygiene ───────────────────────────────────────────────────
    echo -e "\n  ${C_BOLD}Environment Hygiene (AC Risk Check)${C_RESET}"

    # Check for dangerous global variables in current session
    for risky_var in DXVK_ASYNC LD_PRELOAD WINEDEBUG; do
        if printenv "$risky_var" &>/dev/null; then
            local val; val="$(printenv "$risky_var")"
            _diag_check "RISK: ${risky_var}=${val} in global environment" "warn" 0 \
                        "Remove ${risky_var} from /etc/environment, ~/.profile, and ~/.bashrc. Use Steam launch options only."
        else
            _diag_check "${risky_var}: not in global environment" "pass" 1
        fi
    done

    # Check for /etc/environment.d system-wide injection
    if grep -rl 'DXVK\|PROTON\|WINE' /etc/environment.d/ 2>/dev/null | grep -q .; then
        _diag_check "RISK: AC-sensitive vars in /etc/environment.d" "fail" 2 \
                    "Remove: grep -rl 'DXVK\\|PROTON\\|WINE' /etc/environment.d/ and clean those files"
    else
        _diag_check "No AC-sensitive vars in /etc/environment.d" "pass" 2
    fi

    # ── Confidence Score ──────────────────────────────────────────────────────
    local pct=$(( max_score > 0 ? score * 100 / max_score : 0 ))
    local confidence_label
    if   [[ "$pct" -ge 90 ]]; then confidence_label="${C_BGREEN}EXCELLENT${C_RESET}"
    elif [[ "$pct" -ge 70 ]]; then confidence_label="${C_BBLUE}GOOD${C_RESET}"
    elif [[ "$pct" -ge 50 ]]; then confidence_label="${C_BYELLOW}FAIR${C_RESET}"
    else                            confidence_label="${C_BRED}POOR${C_RESET}"
    fi

    echo ""
    echo -e "  ${C_BOLD}$(printf '─%.0s' $(seq 1 60))${C_RESET}"
    echo -e "  ${C_BOLD}Confidence Score: ${score}/${max_score} (${pct}%) — ${confidence_label}${C_RESET}"
    echo -e "  ${C_BOLD}$(printf '─%.0s' $(seq 1 60))${C_RESET}"

    if [[ "${#issues[@]}" -gt 0 ]]; then
        echo ""
        echo -e "  ${C_BOLD}${C_BYELLOW}Issues & Remediation Steps:${C_RESET}"
        for i in "${!issues[@]}"; do
            echo -e "  ${C_BYELLOW}•${C_RESET} ${issues[$i]}"
            [[ -n "${remediation[$i]:-}" ]] && echo -e "    ${C_DIM}→ ${remediation[$i]}${C_RESET}"
        done
    fi
    echo ""
}

# =============================================================================
# SECTION 12 — FULL APPLY ORCHESTRATOR
# =============================================================================

cmd_apply() {
    log_section "APPLY — Profile: ${C_BOLD}${LGCL_PROFILE}${C_RESET}"

    # Print risk ceiling warning for non-stealth profiles
    local max_risk; max_risk="$(get_profile_value "$LGCL_PROFILE" max_risk)"
    if [[ "$max_risk" == "UNSAFE" ]]; then
        echo -e "  ${C_BRED}${C_BOLD}⚠  WARNING: PERFORMANCE PROFILE — UNSAFE OPERATIONS ENABLED  ⚠${C_RESET}"
        echo -e "  ${C_DIM}This profile includes tweaks tagged UNSAFE. These have known"
        echo -e "  anti-cheat detection vectors. Use only for non-competitive or"
        echo -e "  games without kernel-level anti-cheat.${C_RESET}"
        echo ""
        if [[ "${LGCL_FORCE}" != "1" ]]; then
            read -r -p "  Type 'I ACCEPT THE RISK' to continue: " confirm
            [[ "$confirm" != "I ACCEPT THE RISK" ]] && { log_info "Aborted by user."; exit 0; }
        fi
    elif [[ "$max_risk" == "CAUTION" ]]; then
        echo -e "  ${C_BYELLOW}⚠  BALANCED PROFILE — some CAUTION-tagged operations included  ⚠${C_RESET}"
        echo -e "  ${C_DIM}Review risk annotations. Safe for most non-kernel-mode AC titles.${C_RESET}"
        echo ""
    fi

    # Hardware detection is always required before apply
    detect_hardware

    # Create pre-change snapshot
    create_snapshot "pre-apply-${LGCL_PROFILE}"

    local step=0 total=4
    local failed=0

    # Step 1: Kernel layer (requires root)
    ((step++)); echo -e "\n  ${C_BOLD}[${step}/${total}] Kernel & Sysctl Layer${C_RESET}"
    if [[ $EUID -eq 0 ]]; then
        apply_kernel_layer || { log_err "Kernel layer failed"; ((failed++)); }
    else
        log_warn "Not running as root — skipping kernel layer."
        log_warn "Re-run with sudo for kernel parameter tuning."
    fi

    # Step 2: Runtime injection
    ((step++)); echo -e "\n  ${C_BOLD}[${step}/${total}] Runtime Module${C_RESET}"
    apply_runtime_module || { log_err "Runtime module failed"; ((failed++)); }

    # Step 3: Dependency fortress (requires root)
    ((step++)); echo -e "\n  ${C_BOLD}[${step}/${total}] Dependency Fortress${C_RESET}"
    if [[ $EUID -eq 0 ]]; then
        apply_dependency_module || { log_err "Dependency module failed"; ((failed++)); }
    else
        log_warn "Not running as root — skipping package installation."
    fi

    # Step 4: Environment isolation
    ((step++)); echo -e "\n  ${C_BOLD}[${step}/${total}] Environment Isolation${C_RESET}"
    apply_environment_module || { log_err "Environment module failed"; ((failed++)); }

    # Post-apply diagnostics
    echo ""
    log_info "Running post-apply diagnostics..."
    run_diagnostics

    if [[ "$failed" -gt 0 ]]; then
        log_warn "Apply completed with ${failed} module failure(s). Check log: ${LOG_FILE}"
    else
        log_ok "Apply complete. Profile '${LGCL_PROFILE}' is active."
        log_ok "Snapshot for rollback: ${CURRENT_SNAPSHOT_ID}"
    fi

    echo ""
    log_info "Post-install steps required:"
    echo -e "  ${C_DIM}1. Reboot (required for kernel + PAM limits to fully take effect)${C_RESET}"
    echo -e "  ${C_DIM}2. In Steam: Settings → Compatibility → Enable Steam Play for all titles${C_RESET}"
    echo -e "  ${C_DIM}3. Per-game: Properties → Compatibility → Force Proton version${C_RESET}"
    echo -e "  ${C_DIM}4. Copy Steam launch options from: ${LGCL_HOME}/steam_launch_options_${LGCL_PROFILE}.txt${C_RESET}"
    echo ""
}

# =============================================================================
# SECTION 13 — CLI INTERFACE & ARGUMENT PARSER
# =============================================================================

_print_banner() {
    echo -e "${C_BOLD}${C_BCYAN}"
    cat << 'BANNER'
  ██╗      ██████╗  ██████╗██╗
  ██║     ██╔════╝ ██╔════╝██║
  ██║     ██║  ███╗██║     ██║
  ██║     ██║   ██║██║     ██║
  ███████╗╚██████╔╝╚██████╗███████╗
  ╚══════╝ ╚═════╝  ╚═════╝╚══════╝
BANNER
    echo -e "${C_RESET}"
    echo -e "  ${C_BOLD}Linux Gaming Compatibility Layer Manager${C_RESET} ${C_DIM}v${LGCL_VERSION}${C_RESET}"
    echo -e "  ${C_DIM}Anti-Cheat-Aware · Transactional · Hardware-Adaptive · Stealth-First${C_RESET}"
    echo ""
}

_print_help() {
    _print_banner
    cat << EOF
  ${C_BOLD}USAGE${C_RESET}
    lgcl [--profile PROFILE] ACTION [OPTIONS]

  ${C_BOLD}PROFILES${C_RESET}
    --profile stealth      Fully AC-compliant. No experimental flags.
                           Matches Steam baseline behavior exactly. ${C_BGREEN}[DEFAULT]${C_RESET}
    --profile balanced     Safe optimizations. No known AC triggers.
                           Proton-GE allowed. FSR/GameMode enabled.
    --profile performance  Aggressive tuning. ${C_BRED}UNSAFE ops included.${C_RESET}
                           DXVK_ASYNC, split_lock_mitigate=0.
                           Do NOT use with kernel-mode EAC titles.

  ${C_BOLD}ACTIONS${C_RESET}
    --apply                Apply selected profile (all modules)
    --rollback [ID]        Revert changes. Uses last snapshot if ID omitted.
    --diagnose             Run diagnostics engine (stateless, no changes)
    --snapshots            List available rollback snapshots
    --risk-report          Print risk classification for selected profile

  ${C_BOLD}OPTIONS${C_RESET}
    --dry-run              Simulate all changes without writing anything
    --force                Skip version-pin checks; force re-download
    --verbose              Increase log verbosity
    --help                 Show this help

  ${C_BOLD}EXAMPLES${C_RESET}
    ${C_DIM}# Safe setup for EAC/BattlEye competitive titles:${C_RESET}
    sudo lgcl --profile stealth --apply

    ${C_DIM}# Optimized setup for non-competitive or BattlEye-userspace titles:${C_RESET}
    sudo lgcl --profile balanced --apply

    ${C_DIM}# Aggressive setup (non-competitive, no kernel AC):${C_RESET}
    sudo lgcl --profile performance --force --apply

    ${C_DIM}# Diagnostics only (no changes, no root required):${C_RESET}
    lgcl --diagnose

    ${C_DIM}# Undo last apply:${C_RESET}
    sudo lgcl --rollback

    ${C_DIM}# Preview what --apply would do:${C_RESET}
    sudo lgcl --profile balanced --dry-run --apply

  ${C_BOLD}LOG${C_RESET}
    ${LOG_FILE}

  ${C_BOLD}SNAPSHOTS${C_RESET}
    ${LGCL_SNAPSHOT_DIR}

EOF
}

_print_risk_report() {
    log_section "RISK REPORT — Profile: ${C_BOLD}${LGCL_PROFILE}${C_RESET}"
    detect_hardware

    local max_risk; max_risk="$(get_profile_value "$LGCL_PROFILE" max_risk)"
    echo -e "  Risk ceiling: ${C_BOLD}${max_risk}${C_RESET}"
    echo ""

    echo -e "  ${C_BOLD}Parameter Risk Classification${C_RESET}"
    printf "  %-40s %-12s %s\n" "Parameter" "Risk" "Rationale"
    printf "  $(printf '─%.0s' $(seq 1 72))\n"

    local params=(
        "vm.max_map_count (adaptive)|SAFE|Steam sets this; matches expected baseline"
        "fs.file-max (adaptive)|SAFE|Below AC scanner observation threshold"
        "vm.swappiness|SAFE|Standard desktop tuning"
        "kernel.split_lock_mitigate|UNSAFE|Kernel fault behavior; detectable by kernel AC"
        "TCP network tuning|CAUTION|Buffer sizes fingerprinted by some server-side AC"
        "CPU governor change|CAUTION|Readable from /sys by kernel-mode AC"
        "DXVK_ASYNC=1|UNSAFE|Known EAC heuristic trigger in kernel-mode titles"
        "DXVK_ASYNC=0|SAFE|Matches Proton default"
        "PROTON_ESYNC=1|SAFE|Default in official Proton"
        "PROTON_FSYNC=1|SAFE|Default on Steam Deck runtime"
        "WINE_FULLSCREEN_FSR|CAUTION|Alters fullscreen GPU present chain"
        "MangoHud (LD_PRELOAD)|CAUTION|Detectable by kernel-mode AC via /proc/maps"
        "GameMode|CAUTION|Priority changes observable; tolerated by userspace AC"
        "WINEDEBUG (not set)|SAFE|AC checks for debug env as cheat indicator"
        "Global env injection|UNSAFE|Leaks into all processes including AC telemetry"
        "Per-launch env vars|SAFE|Scoped to game invocation only"
    )

    for entry in "${params[@]}"; do
        local param risk rationale
        IFS='|' read -r param risk rationale <<< "$entry"
        local color
        case "$risk" in
            SAFE)    color="$C_BGREEN"   ;;
            CAUTION) color="$C_BYELLOW"  ;;
            UNSAFE)  color="$C_BRED"     ;;
        esac
        printf "  %-40s ${color}%-12s${C_RESET} %s\n" "$param" "$risk" "$rationale"
    done
    echo ""
}

_init_directories() {
    mkdir -p "${LGCL_STATE_DIR}" "${LGCL_SNAPSHOT_DIR}" \
             "${LGCL_PROFILE_DIR}" "${LGCL_LOG_DIR}" \
             "${LGCL_RUNTIME_DIR}"
    touch "${LOG_FILE}"
    _log "BOOT" "LGCL v${LGCL_VERSION} started — PID $$"
}

_acquire_lock() {
    if [[ -f "${LGCL_LOCK_FILE}" ]]; then
        local lock_pid; lock_pid="$(cat "${LGCL_LOCK_FILE}" 2>/dev/null || echo 0)"
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_fatal "Another LGCL instance is running (PID ${lock_pid}). Aborting."
        else
            log_warn "Stale lock file found (PID ${lock_pid} no longer running). Removing."
            rm -f "${LGCL_LOCK_FILE}"
        fi
    fi
    echo $$ > "${LGCL_LOCK_FILE}"
}

_release_lock() {
    rm -f "${LGCL_LOCK_FILE}"
}

_cleanup_and_exit() {
    local code="${1:-0}"
    _release_lock
    [[ -n "${LOG_FILE:-}" ]] && log_dbg "Exit code: ${code}"
    exit "$code"
}

trap '_cleanup_and_exit 1' ERR
trap '_cleanup_and_exit 130' INT TERM

# =============================================================================
# SECTION 14 — MAIN ENTRY POINT
# =============================================================================

main() {
    _init_directories
    _acquire_lock

    # Parse arguments
    local action_set=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                [[ -z "${2:-}" ]] && { echo "Error: --profile requires an argument"; exit 1; }
                case "$2" in
                    stealth|balanced|performance) LGCL_PROFILE="$2" ;;
                    *) echo "Error: Invalid profile '$2'. Choose: stealth|balanced|performance"; exit 1 ;;
                esac
                shift 2 ;;
            --apply)        LGCL_ACTION="apply";       ((action_set++)); shift ;;
            --rollback)
                LGCL_ACTION="rollback"
                LGCL_ROLLBACK_TARGET="${2:-}"
                [[ "${2:-}" != --* ]] && [[ -n "${2:-}" ]] && shift
                ((action_set++)); shift ;;
            --diagnose)     LGCL_ACTION="diagnose";    ((action_set++)); shift ;;
            --snapshots)    LGCL_ACTION="snapshots";   ((action_set++)); shift ;;
            --risk-report)  LGCL_ACTION="risk_report"; ((action_set++)); shift ;;
            --dry-run)      LGCL_DRY_RUN="1"; shift ;;
            --force)        LGCL_FORCE="1"; shift ;;
            --verbose)      LGCL_VERBOSE="1"; shift ;;
            --help|-h)      _print_banner; _print_help; _cleanup_and_exit 0 ;;
            *) echo "Unknown argument: $1. Use --help."; _cleanup_and_exit 1 ;;
        esac
    done

    _print_banner

    [[ "${LGCL_DRY_RUN}" == "1" ]] && {
        echo -e "  ${C_BYELLOW}★ DRY-RUN MODE — No system changes will be made ★${C_RESET}\n"
    }

    if [[ "$action_set" -eq 0 ]]; then
        _print_help
        _cleanup_and_exit 0
    fi

    case "${LGCL_ACTION}" in
        apply)
            cmd_apply
            ;;
        rollback)
            [[ $EUID -ne 0 ]] && log_fatal "Rollback requires root."
            rollback_to_snapshot "${LGCL_ROLLBACK_TARGET:-}"
            ;;
        diagnose)
            detect_hardware
            run_diagnostics
            ;;
        snapshots)
            list_snapshots
            ;;
        risk_report)
            _print_risk_report
            ;;
    esac

    _cleanup_and_exit 0
}

main "$@"
