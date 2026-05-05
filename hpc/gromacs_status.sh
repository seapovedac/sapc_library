#!/usr/bin/env bash
# ==============================================================================
#  gromacs_status.sh — GROMACS MD Simulation Status Explorer
#
#  DISCOVERY: Finds simulation dirs by GROMACS fingerprint files. No directory
#  name assumptions. SLURM logs matched by <prefix>.err.<digits> — any prefix.
#
#  USAGE:
#    ./gromacs_status.sh [ROOT_DIR] [OPTIONS]
#
#  OPTIONS:
#    -p, --pattern NAME      Base name of GROMACS output files, e.g. "9.production"
#                            (skips the interactive prompt)
#        --slurm-prefix PFX  Prefix of SLURM log files (default: MD_SIMULATION)
#    -d, --depth N           Maximum directory search depth (default: unlimited)
#    -e, --errors-only       Show only FAILED / INCOMPLETE simulations
#    -v, --verbose           Show per-sim file inventory below each row
#        --no-color          Disable ANSI color output
#        --no-gromacs-err    Do not parse GROMACS fatal errors
#        --no-mpi-err        Do not parse MPI/parallel errors
#        --no-slurm-out      Do not read SLURM .out file for progress info
#        --no-disk           Do not compute disk usage per simulation
#        --time-unit UNIT    Display time in: ps / ns / us  (default: auto)
#        --dt VAL            Integration timestep in ps (default: 0.02 ps = 20 fs)
#                            Used to convert steps → simulation time
#        --err-lines N       Lines of error context shown inline (default: 3)
#                            Use 0 for label-only, higher for more context
#    -x, --exclude PATTERN   Exclude directories whose path contains PATTERN.
#                            Can be repeated: -x backup -x test -x old
#                            Matched as substring of full path or exact basename.
#    -l, --log [DIR]         Save output to timestamped log (default: ./md_status_logs)
#                            FAILED DETAIL section always goes to log file ONLY.
#    -h, --help              Show this help and exit
#
#  EXAMPLES:
#    ./gromacs_status.sh .
#    ./gromacs_status.sh /scratch/proj -p 9.production
#    ./gromacs_status.sh /scratch/proj -p 9.production --slurm-prefix MD_SIMULATION
#    ./gromacs_status.sh /scratch/proj -p 9.production --dt 0.02 --time-unit ns
#    ./gromacs_status.sh /scratch/proj -p 9.production --err-lines 5
#    ./gromacs_status.sh /scratch/proj -p 9.production --no-disk
# ==============================================================================

set -uo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
setup_colors() {
    if [[ $NO_COLOR -eq 1 ]]; then
        RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; DIM=''; RESET=''
        BLUE=''; MAGENTA=''; WHITE=''; ORANGE=''
    else
        RED='\033[0;31m';    YELLOW='\033[1;33m';  GREEN='\033[0;32m'
        CYAN='\033[0;36m';   BOLD='\033[1m';        DIM='\033[2m'
        RESET='\033[0m';     BLUE='\033[0;34m';     MAGENTA='\033[0;35m'
        WHITE='\033[0;37m';  ORANGE='\033[0;33m'
    fi
}

# ── Defaults ───────────────────────────────────────────────────────────────────
ROOT_DIR="."
SIM_PATTERN=""
SLURM_PREFIX="MD_SIMULATION"
MAX_DEPTH=""
ERRORS_ONLY=0
VERBOSE=0
NO_COLOR=0
PARSE_GMX_ERR=1
PARSE_MPI_ERR=1
READ_SLURM_OUT=1
SHOW_DISK=1
TIME_UNIT="auto"
DT_PS="0.02"          # 20 fs — standard MARTINI CG; override with --dt
ERR_LINES=3
LOG_DIR="./md_status_logs"
declare -a EXCLUDE_PATTERNS=()  # shell glob patterns to exclude from discovery

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pattern)       SIM_PATTERN="$2";    shift 2 ;;
        --slurm-prefix)     SLURM_PREFIX="$2";   shift 2 ;;
        -d|--depth)         MAX_DEPTH="$2";      shift 2 ;;
        -e|--errors-only)   ERRORS_ONLY=1;       shift   ;;
        -v|--verbose)       VERBOSE=1;           shift   ;;
        --no-color)         NO_COLOR=1;          shift   ;;
        --no-gromacs-err)   PARSE_GMX_ERR=0;    shift   ;;
        --no-mpi-err)       PARSE_MPI_ERR=0;    shift   ;;
        --no-slurm-out)     READ_SLURM_OUT=0;   shift   ;;
        --no-disk)          SHOW_DISK=0;         shift   ;;
        --time-unit)        TIME_UNIT="$2";      shift 2 ;;
        --dt)               DT_PS="$2";          shift 2 ;;
        --err-lines)        ERR_LINES="$2";      shift 2 ;;
        -x|--exclude)       EXCLUDE_PATTERNS+=("$2"); shift 2 ;;
        -l|--log)
            if [[ $# -gt 1 && -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                LOG_DIR="$2"; shift
            fi
            shift ;;
        -h|--help)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^#  \?//' | sed 's/^#//'
            exit 0 ;;
        -*) echo "Unknown option: $1  (try -h)" >&2; exit 1 ;;
        *)  ROOT_DIR="$1"; shift ;;
    esac
done

ROOT_DIR="$(realpath "$ROOT_DIR")"
[[ ! -d "$ROOT_DIR" ]] && { echo "ERROR: '$ROOT_DIR' is not a directory." >&2; exit 1; }

setup_colors

# ══════════════════════════════════════════════════════════════════════════════
#  INTERACTIVE PATTERN PROMPT  (skipped if -p was provided)
# ══════════════════════════════════════════════════════════════════════════════
if [[ -z "$SIM_PATTERN" ]]; then
    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║        GROMACS MD Simulation Status Explorer                         ║${RESET}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo -e "  ${BOLD}Step 1 — Output file pattern${RESET}"
    echo -e "  ${DIM}GROMACS names outputs after the simulation step, e.g.:${RESET}"
    echo -e "  ${DIM}  9.production.log  9.production.xtc  9.production.cpt  etc.${RESET}"
    echo
    echo -e "  ${DIM}Scanning for *.log candidates...${RESET}"
    mapfile -t CANDIDATES < <(
        find "$ROOT_DIR" -name "*.log" 2>/dev/null \
            | xargs -I{} basename "{}" \
            | sed 's/\.log$//' \
            | grep -v -E '^\s*$' \
            | sort -u | head -10
    )

    if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
        echo -e "  ${DIM}Detected candidates:${RESET}"
        for i in "${!CANDIDATES[@]}"; do
            printf "    ${CYAN}[%d]${RESET} %s\n" "$((i+1))" "${CANDIDATES[$i]}"
        done
        echo
        echo -e "  Enter a number to select, or type a pattern manually."
        echo -e "  Leave blank for ${DIM}wildcard mode${RESET} (any *.log, *.xtc, etc.)."
    else
        echo -e "  ${DIM}No *.log files found yet — type pattern manually or leave blank.${RESET}"
    fi
    echo
    printf "  ${BOLD}Pattern [e.g. 9.production]:${RESET} "
    read -r user_input </dev/tty

    if [[ "$user_input" =~ ^[0-9]+$ ]] && \
       [[ ${#CANDIDATES[@]} -gt 0 ]] && \
       (( user_input >= 1 && user_input <= ${#CANDIDATES[@]} )); then
        SIM_PATTERN="${CANDIDATES[$((user_input-1))]}"
    else
        SIM_PATTERN="$user_input"
    fi

    echo
    echo -e "  ${BOLD}Step 2 — SLURM log prefix${RESET}"
    echo -e "  ${DIM}Default: ${SLURM_PREFIX}  →  ${SLURM_PREFIX}.err.<jobid>${RESET}"
    printf  "  ${BOLD}SLURM prefix [Enter = keep '${SLURM_PREFIX}']:${RESET} "
    read -r slurm_input </dev/tty
    [[ -n "$slurm_input" ]] && SLURM_PREFIX="$slurm_input"

    [[ -n "$SIM_PATTERN" ]] \
        && echo -e "\n  ${GREEN}Pattern   :${RESET} ${BOLD}${SIM_PATTERN}${RESET}" \
        || echo -e "\n  ${DIM}Pattern   : (wildcard)${RESET}"
    echo -e "  ${GREEN}SLURM pfx :${RESET} ${BOLD}${SLURM_PREFIX}${RESET}"
    echo
fi

# ══════════════════════════════════════════════════════════════════════════════
#  LOG FILE — always on; fd 3 for log-only content (FAILED DETAIL)
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/md_status_$(date '+%Y%m%d_%H%M%S').log"

# Rotate: keep only the 10 most recent log files to avoid accumulation
_old_logs=( $(ls -1t "${LOG_DIR}"/md_status_*.log 2>/dev/null) )
for _f in "${_old_logs[@]:10}"; do rm -f "$_f"; done
unset _old_logs _f

exec 3>"$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>/dev/null

# Trap Ctrl+C and errors — ensure tee child and any open fds are closed cleanly
trap 'exec 3>&- 2>/dev/null; exit 130' INT TERM

# ══════════════════════════════════════════════════════════════════════════════
#  SLURM SNAPSHOT — query once, use for all dirs (avoids per-dir squeue calls)
#  Builds associative array: SLURM_JOBS[job_id]="STATE"
#  STATE values: R=Running  PD=Pending  CG=Completing  F=Failed  etc.
# ══════════════════════════════════════════════════════════════════════════════
declare -A SLURM_JOBS=()      # job_id  → state (R/PD/CG/...)
declare -A SLURM_NAMES=()     # job_id  → job_name
declare -A SLURM_BY_NAME=()   # job_name → job_id  (for name-based matching)
SLURM_AVAILABLE=0
if command -v squeue &>/dev/null; then
    SLURM_AVAILABLE=1
    _sq_user=$(whoami 2>/dev/null || echo "")
    if [[ -n "$_sq_user" ]]; then
        # Format: jobid(18) state(2) name(rest) — separated by single spaces
        while IFS=' ' read -r jid jstate jname; do
            [[ -n "$jid" && "$jid" =~ ^[0-9]+$ ]] || continue
            SLURM_JOBS["$jid"]="$jstate"
            SLURM_NAMES["$jid"]="$jname"
            SLURM_BY_NAME["${jname,,}"]="$jid"   # lowercase key
        done < <(squeue -u "$_sq_user" -h -o "%.18i %.2t %j" 2>/dev/null)
    fi
fi

# match_dir_to_squeue DIR RELPATH
# Returns "JOB_ID STATE" if a squeue job matches this directory.
# Strategy 1 (exact): any .err file job_id found in squeue.
# Strategy 2 (name):  multi-signal match against squeue job names —
#   supports replicaN, rep_N, repN, rep-N replica suffixes;
#   uses sys_num (CCPG1-2SIGMAR style), token overlap, and cross-system
#   exclusion (job has tokens absent from dir → different system).
match_dir_to_squeue() {
    local dir="$1" dirpath="$2"

    # ── Strategy 1: exact match via .err job IDs ───────────────────────────────
    local _ej _id
    while IFS= read -r _ej; do
        _id=$(basename "$_ej" | grep -oE "[0-9]+$")
        [[ -z "$_id" ]] && continue
        if [[ -n "${SLURM_JOBS[$_id]+x}" ]]; then
            echo "$_id ${SLURM_JOBS[$_id]}"
            return
        fi
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null \
        | grep -iE "\.err\.[0-9]+$" \
        | awk -F. '{print $NF"\t"$0}' | sort -k1,1rn | cut -f2-)

    # ── Strategy 2: name-based match ──────────────────────────────────────────
    # Extract replica number — support replicaN, rep_N, repN, rep-N
    local rep_num
    rep_num=$(echo "$dirpath" | grep -oP "(?i)rep(?:lica)?[-_]?\K\d+" | tail -1)
    [[ -z "$rep_num" ]] && return

    # System dir: last path component with rep suffix stripped
    local sys_dir
    sys_dir=$(echo "$dirpath" | grep -oP "[^/]+" | tail -1 \
        | sed 's/[-_]\?[Rr]ep\([Ll]ica\)\?[-_]\?[0-9].*$//' \
        | sed 's/[-_]$//')
    [[ -z "$sys_dir" ]] && sys_dir=$(echo "$dirpath" | grep -oP "[^/]+" | tail -2 | head -1)

    # System number: letter+digits-NUMBER+letter pattern (e.g. CCPG1-2SIGMAR → 2)
    local sys_num
    sys_num=$(echo "$sys_dir" | grep -oP "[A-Z][0-9]*-\K[0-9]+(?=[A-Z])" | head -1)

    # Tokens: use alphanumeric segments (≥3 chars) to handle names like "fam134b"
    local dir_tokens
    dir_tokens=$(echo "$sys_dir" | tr '[:upper:]' '[:lower:]'         | grep -oP "[A-Za-z0-9]{3,}" | grep -v "^[0-9]*$" | tr '\n' '|')

    # Score-based selection: iterate all candidates, pick the best match.
    # Score = number of dir tokens found in job name. This ensures
    # "fam134b-5chol" prefers a job with both "fam134b" AND "chol".
    local best_jid="" best_state="" best_score=0
    local noise="general|memb|prod|step|charmm|gromacs|amber|opls"
    local jid jname jstate

    for jid in "${!SLURM_JOBS[@]}"; do
        jstate="${SLURM_JOBS[$jid]}"
        jname="${SLURM_NAMES[$jid],,}"

        # Replica: job must start with r{N}_ or r{N}-
        [[ "$jname" == "r${rep_num}_"* || "$jname" == "r${rep_num}-"* ]] || continue

        # System number: exact match is strongest — return immediately
        if [[ -n "$sys_num" ]]; then
            echo "$jname" | grep -qP "[-_]${sys_num}([-_]|$)" && { echo "$jid $jstate"; return; }
        fi

        # Cross-check: reject if job has a meaningful token absent from dir
        local skip=0
        while IFS= read -r jt; do
            [[ ${#jt} -lt 3 ]] && continue
            echo "$noise" | grep -q "$jt" && continue
            echo "$dir_tokens" | grep -q "$jt" || { skip=1; break; }
        done < <(echo "$jname" | grep -oP "[a-z0-9]{3,}" | grep -v "^[0-9]*$")
        [[ $skip -eq 1 ]] && continue

        # Score: count dir tokens that appear in job name
        local score=0
        while IFS= read -r dt; do
            [[ ${#dt} -lt 3 ]] && continue
            echo "$jname" | grep -q "$dt" && (( score++ ))
        done < <(echo "$sys_dir" | tr '[:upper:]' '[:lower:]' \
            | grep -oP "[A-Za-z0-9]{3,}" | grep -v "^[0-9]*$")

        if (( score > best_score )); then
            best_score=$score; best_jid=$jid; best_state=$jstate
        fi
    done

    [[ -n "$best_jid" && $best_score -gt 0 ]] && echo "$best_jid $best_state"
}

# ── Find depth ────────────────────────────────────────────────────────────────
depth_args=()
[[ -n "$MAX_DEPTH" ]] && depth_args=(-maxdepth "$MAX_DEPTH")

# ── Fingerprints ──────────────────────────────────────────────────────────────
if [[ -n "$SIM_PATTERN" ]]; then
    FINGERPRINTS=("${SIM_PATTERN}.tpr" "${SIM_PATTERN}.log" "${SIM_PATTERN}.cpt"
                  "${SIM_PATTERN}.edr" "${SIM_PATTERN}.xtc" "${SIM_PATTERN}.trr"
                  "confout.gro")
else
    FINGERPRINTS=("*.tpr" "*.log" "*.cpt" "confout.gro" "*.edr" "*.xtc" "*.trr")
fi

# ── Discovery ─────────────────────────────────────────────────────────────────
discover_sim_dirs() {
    local tmp; tmp=$(mktemp)
    # Primary: GROMACS fingerprint files
    for pattern in "${FINGERPRINTS[@]}"; do
        find "$ROOT_DIR" "${depth_args[@]}" -name "$pattern" -print0 2>/dev/null \
            | xargs -0 -I{} dirname "{}" >> "$tmp" 2>/dev/null || true
    done
    # Secondary: SLURM log files (*.err.<digits> / *.out.<digits>) —
    # catches dirs where a job was submitted but GROMACS hasn't created
    # output files yet (e.g. grompp runs inside the job script).
    find "$ROOT_DIR" "${depth_args[@]}" -type f 2>/dev/null \
        | grep -iE "(/${SLURM_PREFIX}\.[Ee][Rr][Rr]\.[0-9]+|/${SLURM_PREFIX}\.[Oo][Uu][Tt]\.[0-9]+)$" \
        | xargs -I{} dirname "{}" >> "$tmp" 2>/dev/null || true

    # Resolve log dir for exact exclusion
    local logdir_real; logdir_real=$(realpath "$LOG_DIR" 2>/dev/null || echo "$LOG_DIR")

    while IFS= read -r d; do
        # Exclude the status log directory itself (any depth match)
        [[ "$d" == "$LOG_DIR"      ]] && continue
        [[ "$d" == "$logdir_real"  ]] && continue
        # Exclude any path that has md_status_logs as a path component
        [[ "$d" == *"/md_status_logs"* ]] && continue
        [[ "$d" == *"/md_status_logs"  ]] && continue

        # Exclude paths matching any user-supplied --exclude pattern
        # Pattern is matched against the full absolute path and the basename
        local _skip=0 _xp
        for _xp in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
            # shellcheck disable=SC2254
            if [[ "$d" == *"${_xp}"* || "$(basename "$d")" == ${_xp} ]]; then
                _skip=1; break
            fi
        done
        [[ $_skip -eq 1 ]] && continue

        # Require the directory to contain at least one unambiguous GROMACS file
        # (*.tpr, *.edr, *.xtc, *.trr, *.cpt, confout.gro) OR a SLURM log file
        # matching the configured prefix (job submitted but not yet started).
        local is_sim=0
        for ext in tpr edr xtc trr cpt; do
            if [[ -n "$(find "$d" -maxdepth 1 -name "*.${ext}" 2>/dev/null | head -1)" ]]; then
                is_sim=1; break
            fi
        done
        [[ -f "$d/confout.gro" ]] && is_sim=1
        # Accept dirs with a SLURM log — job submitted, files not yet created
        if [[ $is_sim -eq 0 ]]; then
            [[ -n "$(find "$d" -maxdepth 1 -type f                 -name "${SLURM_PREFIX}.err.*" -o                 -name "${SLURM_PREFIX}.out.*" 2>/dev/null | head -1)" ]] && is_sim=1
        fi
        [[ $is_sim -eq 0 ]] && continue

        echo "$d"
    done < <(sort -u "$tmp")
    rm -f "$tmp"
}

# ── SLURM file helpers ─────────────────────────────────────────────────────────
latest_slurm_file() {
    local dir="$1" ext="$2"
    local f
    f=$(find "$dir" -maxdepth 1 -type f -name "${SLURM_PREFIX}.${ext}.*" 2>/dev/null \
        | grep -E "\.[0-9]+$" \
        | awk -F'.' '{print $NF"\t"$0}' | sort -k1,1n | tail -1 | cut -f2-)
    if [[ -z "$f" ]]; then
        f=$(find "$dir" -maxdepth 1 -type f 2>/dev/null \
            | grep -iE "\.${ext}\.[0-9]+$" \
            | awk -F'.' '{print $NF"\t"$0}' | sort -k1,1n | tail -1 | cut -f2-)
    fi
    echo "$f"
}
job_id_from_file() { basename "$1" | grep -oE '[0-9]+$' || echo "-"; }
recently_modified() { [[ -f "$1" ]] && [[ -n "$(find "$1" -mmin -"$2" 2>/dev/null)" ]]; }

# ── Steps → ps via dt ─────────────────────────────────────────────────────────
steps_to_ps() {
    local steps="$1"
    [[ "$steps" == "-" || -z "$steps" ]] && echo "-" && return
    [[ "$steps" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "-"; return; }
    awk -v s="$steps" -v dt="$DT_PS" 'BEGIN{printf "%.6g", s * dt}'
}

# ── Time display ──────────────────────────────────────────────────────────────
convert_time() {
    local val_ps="$1"
    [[ "$val_ps" == "-" || -z "$val_ps" ]] && echo "-" && return
    [[ "$val_ps" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || { echo "-"; return; }
    local unit="$TIME_UNIT"
    if [[ "$unit" == "auto" ]]; then
        local iv; iv=$(awk -v v="$val_ps" 'BEGIN{printf "%d", v}')
        if   (( iv >= 1000000 )); then unit="us"
        elif (( iv >= 1000    )); then unit="ns"
        else                           unit="ps"
        fi
    fi
    case "$unit" in
        us) awk -v v="$val_ps" 'BEGIN{printf "%.4f µs", v/1000000}' ;;
        ns) awk -v v="$val_ps" 'BEGIN{printf "%.3f ns",  v/1000}'   ;;
        ps) awk -v v="$val_ps" 'BEGIN{printf "%.2f ps",  v}'        ;;
        *)  awk -v v="$val_ps" 'BEGIN{printf "%.2f ps",  v}'        ;;
    esac
}

# ── Parse last simulated time from md log ────────────────────────────────────
parse_last_time_ps() {
    local f="$1" t=""
    # A: "Step  Time" data block  (time already in ps)
    t=$(grep -A2 "^\s*Step\s*Time" "$f" 2>/dev/null \
        | grep -v "Step\|^--$" | grep -E "^\s*[0-9]" | tail -1 | awk '{print $2}')
    # B: "Time:  <val>" line
    [[ -z "$t" || "$t" == "0" ]] && \
        t=$(grep -oP 'Time:\s+\K[0-9]+\.?[0-9]*' "$f" 2>/dev/null | tail -1)
    # C: progress "step NNNNN" — step number, multiply by dt
    if [[ -z "$t" || "$t" == "0" ]]; then
        local steps
        steps=$(grep -oP 'step\s+\K[0-9]+' "$f" 2>/dev/null | tail -1)
        [[ -n "$steps" ]] && t=$(steps_to_ps "$steps")
    fi
    echo "${t:--}"
}

# parse_last_step: returns the last MD step number reached (integer)
parse_last_step() {
    local f="$1" step=""
    # A: "Step  Time" data block in md log — first column is the step
    step=$(grep -A2 "^[[:space:]]*Step[[:space:]]*Time" "$f" 2>/dev/null \
        | grep -v "Step\|^--$" | grep -E "^[[:space:]]*[0-9]" | tail -1 | awk '{print $1}')
    # B: progress lines "imb F XX% step NNNNN,"
    [[ -z "$step" || "$step" == "0" ]] && \
        step=$(grep -oP 'step[[:space:]]+\K[0-9]+' "$f" 2>/dev/null | tail -1)
    echo "${step:--}"
}

# ── Atom count from log ───────────────────────────────────────────────────────
parse_atoms() {
    grep -oP 'There are:\s+\K[0-9]+(?=\s+Atoms)' "$1" 2>/dev/null | head -1 || echo "-"
}

# ── Performance block (FINISHED sims) ────────────────────────────────────────
# GROMACS writes a block like:
#            Wall time (s):  123456.789
#           Performance:
#             Mnbf/s:    123.45
#             GFlops:    45.67
#           ns/day:  2.345
#           hours/ns: 10.234
parse_performance() {
    # GROMACS 2021+ log performance block format:
    #
    #   Performance:   ns/day   hours/ns     ← header line
    #                    2.348     10.221    ← data line (next line)
    #
    #          Core t (s)   Wall t (s)        (%)
    #   Time:   983442.900    2458.700    400.0
    #                              ↑ wall time in seconds (column 3)
    local f="$1"
    local ns_day="" hours_ns="" wall_time="" wall_fmt="-"

    # ns/day + hours/ns: GROMACS writes these in different layouts depending on version:
    #   Layout A (2021+): "Performance:  ns/day  hours/ns" header, values on next line
    #   Layout B (older): "Performance:" alone, then "ns/day  hours/ns" header, values on next line
    #   Layout C (some):  "Performance:   4.155   5.775" values on same line
    local perf_data
    # Try layout A: header and values separated — grep header line, take next data line
    perf_data=$(grep -A2 'Performance:' "$f" 2>/dev/null \
        | grep -v 'Performance:' | grep -v '^--$' \
        | grep -E '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$perf_data" ]]; then
        # The data line has two floats: ns/day and hours/ns
        ns_day=$(echo   "$perf_data" | awk '{for(i=1;i<=NF;i++) if($i+0>0){print $i; exit}}')
        hours_ns=$(echo "$perf_data" | awk '{found=0; for(i=1;i<=NF;i++) if($i+0>0){if(found){print $i; exit} found=1}}')
        [[ "$ns_day"   =~ ^[0-9]+\.?[0-9]*$ ]] || ns_day=""
        [[ "$hours_ns" =~ ^[0-9]+\.?[0-9]*$ ]] || hours_ns=""
    fi
    # Fallback: values on the same line as Performance:
    if [[ -z "$ns_day" ]]; then
        local perf_line
        perf_line=$(grep 'Performance:' "$f" 2>/dev/null | grep -E '[0-9]+\.[0-9]+' | tail -1)
        if [[ -n "$perf_line" ]]; then
            ns_day=$(echo   "$perf_line" | grep -oP '[0-9]+\.[0-9]+' | head -1)
            hours_ns=$(echo "$perf_line" | grep -oP '[0-9]+\.[0-9]+' | tail -1)
            [[ "$ns_day" == "$hours_ns" ]] && hours_ns=""
        fi
    fi

    # Wall time in seconds: "Time:  <core_t>  <wall_t>  <pct>" — column 3 is wall_t
    wall_time=$(grep '^\s*Time:' "$f" 2>/dev/null | tail -1 | awk '{print $3}')
    [[ "$wall_time" =~ ^[0-9]+\.?[0-9]*$ ]] || wall_time=""

    if [[ -n "$wall_time" && "$wall_time" != "0" ]]; then
        wall_fmt=$(awk -v s="$wall_time" 'BEGIN{
            h=int(s/3600); m=int((s%3600)/60); sec=int(s%60)
            printf "%02dh%02dm%02ds", h, m, sec
        }')
    fi

    # Build a single formatted line:  ns/day: 4.155   hours/ns: 5.775   wall time: 66h44m07s
    local out=""
    [[ -n "$ns_day"    ]] && out+="ns/day: ${ns_day}   "
    [[ -n "$hours_ns"  ]] && out+="hours/ns: ${hours_ns}   "
    [[ "$wall_fmt" != "-" ]] && out+="wall time: ${wall_fmt}"
    out="${out%   }"   # strip trailing spaces
    echo "${out:--}"
}

# ── SLURM .out progress ───────────────────────────────────────────────────────
parse_slurm_out_progress() {
    grep -E "step [0-9]+(,| )" "$1" 2>/dev/null | tail -1 \
        | sed 's/^[[:space:]]*//' | cut -c1-70 || true
}

# ── GROMACS fatal error block ─────────────────────────────────────────────────
# Extracts meaningful content lines from the canonical "----" block.
# Skips: Program: Source file: MPI rank: For more: website: empty lines:
#         and lines that are only a filename (*.cpt *.gro etc.)
extract_gmx_error() {
    local f="$1" n="${ERR_LINES}"

    # Lines to skip inside the block (boilerplate / noise)
    local skip_pat='Program:|Source file:|MPI rank:|For more|website at |^[[:space:]]*$'
    # Lines that are just a bare filename — not useful inline
    local fname_pat='^[^/ ]+\.(cpt|gro|tpr|xtc|trr|mdp|top|itp|edr|log)[[:space:]]*$'

    if [[ "$n" -eq 0 ]]; then
        awk -v skip="$skip_pat" -v fname="$fname_pat" '
            /^-{5,}/ { in_block=!in_block; next }
            in_block && ($0 ~ skip || $0 ~ fname) { next }
            in_block && NF>0 { sub(/^[[:space:]]+/,""); print; exit }
        ' "$f" 2>/dev/null | head -1
        return
    fi

    awk -v maxn="$n" -v skip="$skip_pat" -v fname="$fname_pat" '
        /^-{5,}/ {
            if (in_block && found && NR_content > 0) { exit }
            in_block = !in_block; next
        }
        in_block && ($0 ~ skip || $0 ~ fname) { next }
        in_block && NF>0 {
            found=1; sub(/^[[:space:]]+/,""); print
            NR_content++
            if (NR_content >= maxn) exit
        }
    ' "$f" 2>/dev/null | grep -v '^$' | head -"$n"
}

# ── MPI / parallel error block ────────────────────────────────────────────────
# Extracts meaningful sentences, skips separator lines, Proc:/Errorcode:/NOTE:
extract_mpi_error() {
    local f="$1" n="${ERR_LINES}"

    # Patterns to skip (separators, process IDs, generic notes)
    # Skip separator lines and pure-noise lines; keep MPI_ABORT line itself
    local skip_pat='^-{5,}|^[[:space:]]*$|Proc:[[:space:]]*\[\[|Errorcode:|^NOTE:|You may or may not|exactly when Open MPI|This may have caused|terminated by signals sent'

    if [[ "$n" -eq 0 ]]; then
        grep -iEm1 \
            'MPI_ABORT|prterun.*exit|rank.*abort|process.*non-zero|OOM|[Ss]egfault|[Kk]illed' \
            "$f" 2>/dev/null | grep -vE "$skip_pat" \
            | sed 's/^[[:space:]]*//' | cut -c1-80
        return
    fi

    grep -iE \
        'MPI_ABORT was invoked|MPI_ABORT was called|prterun has exited|prterun detected|rank [0-9]+ with PID|process.*non-zero status|OOM killer|[Ss]egmentation [Ff]ault|[Ss]egfault|[Bb]us error' \
        "$f" 2>/dev/null \
        | grep -vE "$skip_pat" \
        | head -"$n" \
        | sed 's/^[[:space:]]*//' | cut -c1-80
}

# ── Generic SLURM errors ──────────────────────────────────────────────────────
extract_generic_error() {
    local result
    result=$(grep -iE \
        'sbatch: error|cannot allocate|No such file or directory|Permission denied|Disk quota|CUDA error|sed:' \
        "$1" 2>/dev/null \
        | grep -vE '^[[:space:]]*$' \
        | head -"${ERR_LINES}" \
        | sed 's/^[[:space:]]*//' | cut -c1-80)
    echo "${result:--}"
}

# ── File finders ──────────────────────────────────────────────────────────────
find_sim_log() {
    local dir="$1"
    [[ -n "$SIM_PATTERN" ]] \
        && find "$dir" -maxdepth 1 -name "${SIM_PATTERN}.log" 2>/dev/null | head -1 \
        || find "$dir" -maxdepth 1 -name "*.log" 2>/dev/null \
             | grep -vE '\.(err|out)\.[0-9]+$' | head -1
}

find_sim_xtc() {
    local dir="$1"
    if [[ -n "$SIM_PATTERN" ]]; then
        local f
        f=$(find "$dir" -maxdepth 1 -name "${SIM_PATTERN}.xtc" 2>/dev/null | head -1)
        [[ -z "$f" ]] && f=$(find "$dir" -maxdepth 1 -name "${SIM_PATTERN}.trr" 2>/dev/null | head -1)
        echo "$f"
    else
        find "$dir" -maxdepth 1 \( -name "*.xtc" -o -name "*.trr" \) 2>/dev/null | head -1
    fi
}

find_by_ext() {
    local dir="$1" ext="$2"
    [[ -n "$SIM_PATTERN" ]] \
        && find "$dir" -maxdepth 1 -name "${SIM_PATTERN}.${ext}" 2>/dev/null | head -1 \
        || find "$dir" -maxdepth 1 -name "*.${ext}" ! -name "#*" 2>/dev/null | head -1
}

# ── Disk usage for a directory ────────────────────────────────────────────────
dir_disk_usage() {
    # timeout guards against slow/hung network filesystems (panfs, lustre, etc.)
    timeout 15 du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "?"
}

# ── Classify a simulation directory ──────────────────────────────────────────
# Output (pipe-separated):
#   STATUS | GMX_ENC | MPI_ENC | GEN_ERR | PERF_ENC | PROGRESS
#   | FRAMES | TIME_PS | JOB_ID | ATOMS | DISK
#   | has_tpr | has_log | has_xtc | has_cpt | has_edr | has_confout
classify_sim() {
    local dir="$1"

    local tpr mdlog xtc cpt confout edr err_file out_file
    tpr=$(     find_by_ext  "$dir" "tpr")
    mdlog=$(   find_sim_log "$dir")
    xtc=$(     find_sim_xtc "$dir")
    cpt=$(     find_by_ext  "$dir" "cpt")
    edr=$(     find_by_ext  "$dir" "edr")
    # Final coordinate file — search in priority order:
    #   1. confout.gro          (GROMACS default output name)
    #   2. ${SIM_PATTERN}.gro   (when mdrun -c is set to the pattern)
    #   3. ${SIM_PATTERN}*.gro  (any variant suffix, e.g. _final.gro)
    #   4. any *.gro newer than the .tpr (produced by this run, not input)
    # Final coordinate file — pattern-specific search only.
    # The -newer $tpr wildcard fallback is applied LATER, only when fin_log=1,
    # to avoid matching equilibration/input .gro files in running simulations.
    confout=""
    confout=$(find "$dir" -maxdepth 1 -name "confout.gro" 2>/dev/null | head -1)
    if [[ -z "$confout" && -n "$SIM_PATTERN" ]]; then
        confout=$(find "$dir" -maxdepth 1 -name "${SIM_PATTERN}.gro" 2>/dev/null | head -1)
    fi
    if [[ -z "$confout" && -n "$SIM_PATTERN" ]]; then
        confout=$(find "$dir" -maxdepth 1 -name "${SIM_PATTERN}*.gro" 2>/dev/null | head -1)
    fi
    err_file=$(latest_slurm_file "$dir" "err")
    out_file=$(latest_slurm_file "$dir" "out")

    local has_tpr=0 has_log=0 has_xtc=0 has_cpt=0 has_edr=0 has_confout=0
    [[ -n "$tpr"     ]] && has_tpr=1
    [[ -n "$mdlog"   ]] && has_log=1
    [[ -n "$xtc"     ]] && has_xtc=1
    [[ -n "$cpt"     ]] && has_cpt=1
    [[ -n "$edr"     ]] && has_edr=1
    [[ -n "$confout" ]] && has_confout=1

    local status="UNKNOWN"
    local gmx_lines="" mpi_lines="" gen_err="-" progress="-" perf_enc="-"
    local steps="-" time_ps="-" job_id="-" atoms="-" disk="-"
    local fin_log=0  # set early — used both in FINISHED and FINALIZED checks

    [[ -n "$err_file" ]] && job_id="$(job_id_from_file "$err_file")"
    [[ -n "$mdlog"    ]] && time_ps="$(parse_last_time_ps "$mdlog")"
    [[ -n "$mdlog"    ]] && steps="$(parse_last_step "$mdlog")"
    # If log gave no step, also try the SLURM .out progress lines
    if [[ "$steps" == "-" && -n "$out_file" && -s "$out_file" ]]; then
        steps="$(parse_last_step "$out_file")"
    fi
    # Time from .out if log gave nothing
    if [[ "$time_ps" == "-" || "$time_ps" == "0" ]] && [[ -n "$out_file" && -s "$out_file" ]]; then
        time_ps="$(parse_last_time_ps "$out_file")"
    fi
    [[ -n "$mdlog"    ]] && atoms="$(parse_atoms "$mdlog")"
    [[ $SHOW_DISK -eq 1 ]] && disk="$(dir_disk_usage "$dir")"
    # Detect clean mdrun finish early — used by both FINISHED and FINALIZED
    [[ -n "$mdlog" ]] && grep -q "Finished mdrun" "$mdlog" 2>/dev/null && fin_log=1
    # Only now apply the wildcard -newer fallback — gated on fin_log=1 so we
    # don't pick up equilibration/input .gro files in still-running simulations.
    if [[ $fin_log -eq 1 && -z "$confout" && -n "$tpr" ]]; then
        confout=$(find "$dir" -maxdepth 1 -name "*.gro" -newer "$tpr" 2>/dev/null | head -1)
        [[ -n "$confout" ]] && has_confout=1
    fi
    # If mdrun finished cleanly it always wrote a final structure — mark gro:●
    # even if we could not determine the exact filename from disk.
    [[ $fin_log -eq 1 ]] && has_confout=1

    # SLURM .out
    if [[ $READ_SLURM_OUT -eq 1 && -n "$out_file" && -s "$out_file" ]]; then
        progress="$(parse_slurm_out_progress "$out_file")"
        if [[ "$time_ps" == "-" || "$time_ps" == "0" ]]; then
            local steps_out
            steps_out=$(grep -oP 'step\s+\K[0-9]+' "$out_file" 2>/dev/null | tail -1)
            [[ -n "$steps_out" ]] && time_ps="$(steps_to_ps "$steps_out")"
        fi
    fi

    # Errors — GROMACS writes its error block to .out (stdout) mixed with
    # progress lines. MPI runtime messages go to .err (stderr).
    # Strategy: extract GROMACS errors from .out (where the "------" block lives),
    #           extract MPI errors from .err (where MPI_ABORT/prterun messages go),
    #           extract generic errors from both, deduplicate.
    local src_gmx=""   # file to extract GROMACS block from
    local src_mpi=""   # file to extract MPI lines from
    local src_gen=""   # file to extract generic errors from

    # GROMACS "-------" error block appears in .out when gmx writes stdout there,
    # but also sometimes in .err. Try .out first, fall back to .err.
    if [[ $READ_SLURM_OUT -eq 1 && -n "$out_file" && -s "$out_file" ]]; then
        grep -q "Program:.*gmx\|File input/output error\|Fatal error" "$out_file" 2>/dev/null             && src_gmx="$out_file" || src_gmx="${err_file:-}"
    else
        src_gmx="${err_file:-}"
    fi
    src_mpi="${err_file:-}"   # MPI runtime always goes to stderr

    # For generic errors, check both and merge
    local gen_err_file; gen_err_file=$(mktemp)
    [[ -n "$err_file" && -s "$err_file" ]] && cat "$err_file" >> "$gen_err_file"
    [[ $READ_SLURM_OUT -eq 1 && -n "$out_file" && -s "$out_file" ]] && cat "$out_file" >> "$gen_err_file"

    local any_error=0
    if [[ -n "$src_gmx" && -s "$src_gmx" && $PARSE_GMX_ERR -eq 1 ]]; then
        gmx_lines="$(extract_gmx_error "$src_gmx")"
        [[ -n "$gmx_lines" ]] && any_error=1
    fi
    if [[ $PARSE_MPI_ERR -eq 1 ]]; then
        # MPI messages can appear in either .err or .out depending on MPI implementation.
        # Scan both and merge, deduplicate by exact line.
        local mpi_tmp; mpi_tmp=$(mktemp)
        [[ -n "$err_file" && -s "$err_file" ]] && extract_mpi_error "$err_file" >> "$mpi_tmp"
        [[ $READ_SLURM_OUT -eq 1 && -n "$out_file" && -s "$out_file" ]] &&             extract_mpi_error "$out_file" >> "$mpi_tmp"
        mpi_lines=$(sort -u "$mpi_tmp")
        rm -f "$mpi_tmp"
        [[ -n "$mpi_lines" ]] && any_error=1
    fi
    if [[ -s "$gen_err_file" ]]; then
        local gen_raw
        gen_raw="$(extract_generic_error "$gen_err_file")"
        gen_err="$(echo "$gen_raw" | tr '\n' '^' | sed 's/\^$//')"
        [[ -z "$gen_err" ]] && gen_err="-"
        [[ "$gen_err" != "-" ]] && any_error=1
    fi
    rm -f "$gen_err_file"
    if [[ $any_error -eq 1 ]]; then
        # If the MD simulation itself finished cleanly ("Finished mdrun" in log)
        # but only post-processing/script errors were found (no GROMACS fatal
        # block, no MPI abort) → the run is FINALIZED, not FAILED.
        if [[ $fin_log -eq 1 && -z "$gmx_lines" && -z "$mpi_lines" ]]; then
            status="FINISHED"
            [[ -n "$mdlog" ]] && perf_enc="$(parse_performance "$mdlog")"
        else
            status="FAILED"
        fi
    fi

    # Clean finish — "Finished mdrun" in the GROMACS log is the primary signal.
    # confout.gro (or pattern.gro) is checked for the files column display only;
    # its absence does not prevent FINISHED (it may have been moved or renamed).
    if [[ "$status" != "FAILED" && $fin_log -eq 1 ]]; then
        status="FINISHED"
        [[ -n "$mdlog" ]] && perf_enc="$(parse_performance "$mdlog")"
    fi

    # ── File-based fallback status ───────────────────────────────────────────
    [[ "$status" == "UNKNOWN" && -n "$cpt" ]] && recently_modified "$cpt" 60 \
        && status="RUNNING"
    [[ "$status" == "UNKNOWN" && ( -n "$cpt" || -n "$edr" ) ]] && status="INCOMPLETE"
    [[ "$status" == "UNKNOWN" ]] && { [[ -n "$tpr" ]] && status="NOT_STARTED" || status="NO_TPR"; }

    # ── SLURM authoritative override ──────────────────────────────────────────
    # match_dir_to_squeue tries two strategies:
    #   1. Exact: any .err file job_id found in squeue       (running/just-started)
    #   2. Name:  replica+system numbers matched to job name  (PD, no .err yet)
    if [[ $SLURM_AVAILABLE -eq 1 ]]; then
        local sq_result sq_jid sq_state
        sq_result=$(match_dir_to_squeue "$dir" "$(rel_path "$dir")")
        sq_jid="${sq_result%% *}"
        sq_state="${sq_result##* }"

        if [[ -n "$sq_state" && -n "$sq_jid" ]]; then
            case "$sq_state" in
                R|RUNNING)
                    status="RUNNING"; job_id="$sq_jid" ;;
                PD|PENDING)
                    status="QUEUED";  job_id="${sq_jid} (PD)" ;;
                CG|COMPLETING)
                    status="RUNNING"; job_id="${sq_jid} (CG)" ;;
                F|FAILED|TO|TIMEOUT|OOM|OUT_OF_MEMORY)
                    [[ "$status" != "FAILED" ]] && status="FAILED"
                    job_id="$sq_jid" ;;
            esac
        fi
    fi

    # Encode multiline blocks as ^-separated
    local gmx_enc mpi_enc
    gmx_enc="$(echo "$gmx_lines" | tr '\n' '^' | sed 's/\^$//')"
    mpi_enc="$(echo "$mpi_lines" | tr '\n' '^' | sed 's/\^$//')"
    # Sanitize pipes
    for v in gmx_enc mpi_enc gen_err progress perf_enc disk; do
        printf -v "$v" '%s' "${!v//|/,}"
    done
    [[ -z "$gmx_enc"  ]] && gmx_enc="-"
    [[ -z "$mpi_enc"  ]] && mpi_enc="-"
    [[ -z "$progress" ]] && progress="-"

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%d|%d|%d|%d|%d|%d\n' \
        "$status" "$gmx_enc" "$mpi_enc" "$gen_err" "$perf_enc" "$progress" \
        "$steps" "$time_ps" "$job_id" "$atoms" "$disk" \
        "$has_tpr" "$has_log" "$has_xtc" "$has_cpt" "$has_edr" "$has_confout"

    if [[ $VERBOSE -eq 1 ]]; then
        printf 'VERBOSE|tpr=%s|log=%s|xtc=%s|cpt=%s|edr=%s|confout=%s|err=%s|out=%s\n' \
            "$(basename "${tpr:--}")"      "$(basename "${mdlog:--}")"   \
            "$(basename "${xtc:--}")"      "$(basename "${cpt:--}")"     \
            "$(basename "${edr:--}")"      "$(basename "${confout:--}")" \
            "$(basename "${err_file:--}")" "$(basename "${out_file:--}")"
    fi
}

# ── Files column ──────────────────────────────────────────────────────────────
files_column() {
    local ok="${GREEN}●${RESET}" no="${DIM}○${RESET}"
    printf "tpr:%b log:%b xtc:%b cpt:%b edr:%b gro:%b" \
        "$([[ $1 == 1 ]] && echo -e "$ok" || echo -e "$no")" \
        "$([[ $2 == 1 ]] && echo -e "$ok" || echo -e "$no")" \
        "$([[ $3 == 1 ]] && echo -e "$ok" || echo -e "$no")" \
        "$([[ $4 == 1 ]] && echo -e "$ok" || echo -e "$no")" \
        "$([[ $5 == 1 ]] && echo -e "$ok" || echo -e "$no")" \
        "$([[ $6 == 1 ]] && echo -e "$ok" || echo -e "$no")"
}

status_label() {
    case "$1" in
        FINISHED)    printf "${GREEN}FINISHED   ✔${RESET}"  ;;
        RUNNING)     printf "${CYAN}RUNNING    ▶${RESET}"   ;;
        FAILED)      printf "${RED}FAILED     ✖${RESET}"    ;;
        INCOMPLETE)  printf "${YELLOW}INCOMPLETE ⚠${RESET}" ;;
        QUEUED)      printf "${BLUE}QUEUED     ⏳${RESET}"   ;;
        NOT_STARTED) printf "${DIM}NOT_STARTED○${RESET}"    ;;
        NO_TPR)      printf "${MAGENTA}NO_TPR     ✗${RESET}";;
        *)           printf "${WHITE}UNKNOWN    ?${RESET}"   ;;
    esac
}

rel_path() { local r="${1#"$ROOT_DIR"/}"; echo "${r:-.}"; }

# ── Print encoded multiline block ─────────────────────────────────────────────
# $1=encoded(^-sep)  $2=color  $3=label  $4=tree-char(├ or └)
print_block() {
    local encoded="$1" color="$2" label="$3" char="$4"
    [[ "$encoded" == "-" || -z "$encoded" ]] && return
    local old_IFS="$IFS"; IFS='^'
    local lines=($encoded)
    IFS="$old_IFS"
    for line in "${lines[@]}"; do
        [[ -z "$line" ]] && continue
        echo -e "    ${color}${char} ${label}${RESET} ${DIM}${line}${RESET}"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN OUTPUT
# ══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║        GROMACS MD Simulation Status Explorer                         ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo -e "  ${DIM}Root         : ${ROOT_DIR}${RESET}"
echo -e "  ${DIM}Date         : $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "  ${DIM}Pattern      : ${SIM_PATTERN:-(wildcard)}${RESET}"
echo -e "  ${DIM}SLURM prefix : ${SLURM_PREFIX}${RESET}"
echo -e "  ${DIM}dt           : ${DT_PS} ps  (steps × dt → simulation time)${RESET}"
[[ -n "$MAX_DEPTH"  ]] && echo -e "  ${DIM}Max depth    : ${MAX_DEPTH}${RESET}"
echo -e "  ${DIM}Time unit    : ${TIME_UNIT}${RESET}"
echo -e "  ${DIM}Err lines    : ${ERR_LINES}${RESET}"
echo -e "  ${DIM}GROMACS err  : $([[ $PARSE_GMX_ERR  -eq 1 ]] && echo ON || echo OFF)${RESET}"
echo -e "  ${DIM}MPI err      : $([[ $PARSE_MPI_ERR  -eq 1 ]] && echo ON || echo OFF)${RESET}"
echo -e "  ${DIM}SLURM .out   : $([[ $READ_SLURM_OUT -eq 1 ]] && echo ON || echo OFF)${RESET}"
echo -e "  ${DIM}Disk usage   : $([[ $SHOW_DISK      -eq 1 ]] && echo ON || echo OFF)${RESET}"
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    echo -e "  ${DIM}Excluding    : ${EXCLUDE_PATTERNS[*]}${RESET}"
fi
if [[ $SLURM_AVAILABLE -eq 1 ]]; then
    echo -e "  ${DIM}SLURM jobs   : ${#SLURM_JOBS[@]} active jobs found in squeue${RESET}"
else
    echo -e "  ${YELLOW}SLURM squeue : not available — status based on files only${RESET}"
fi
echo -e "  ${DIM}Log file     : ${LOGFILE}${RESET}"
echo

echo -e "  ${DIM}Scanning fingerprints: ${FINGERPRINTS[*]}${RESET}"
echo

mapfile -t SIM_DIRS < <(discover_sim_dirs)

# ── squeue-guided discovery ────────────────────────────────────────────────────
# For PD jobs that haven't created any files yet (no .tpr, no SLURM logs),
# try to find their directory by matching the job name against subdir names.
if [[ $SLURM_AVAILABLE -eq 1 ]]; then
    declare -A _discovered=()
    for _d in "${SIM_DIRS[@]}"; do _discovered["$_d"]=1; done

    for _jid in "${!SLURM_JOBS[@]}"; do
        [[ "${SLURM_JOBS[$_jid]}" != "PD" && "${SLURM_JOBS[$_jid]}" != "PENDING" ]] && continue
        _jname="${SLURM_NAMES[$_jid],,}"

        # Extract replica number from job name (r{N}_ prefix)
        _jrep=$(echo "$_jname" | grep -oP "^r\K\d+(?=[_-])")
        [[ -z "$_jrep" ]] && continue

        # Search all direct subdirs of ROOT_DIR for a name match
        while IFS= read -r -d '' _subdir; do
            [[ -n "${_discovered[$_subdir]+x}" ]] && continue  # already found

            _bname=$(basename "$_subdir")
            _bname_lower="${_bname,,}"

            # Replica check: dir must contain rep{N} or replica{N}
            _drep=$(echo "$_bname" | grep -oP "(?i)rep(?:lica)?[-_]?\K\d+" | tail -1)
            [[ "$_drep" != "$_jrep" ]] && continue

            # Token check: extract alphanumeric segments (3+ chars) from both names.
            # Handles names like "fam134b" that have no pure-alpha 4-char words.
            local_match=0
            while IFS= read -r _tok; do
                [[ ${#_tok} -lt 3 ]] && continue
                echo "$_jname" | grep -qi "$_tok" && { local_match=1; break; }
            done < <(echo "$_bname_lower" | grep -oP "[A-Za-z0-9]{3,}")
            # If no tokens matched and dir has no meaningful tokens → replica alone ok
            if [[ $local_match -eq 0 ]]; then
                _dtc=$(echo "$_bname_lower" | grep -oP "[A-Za-z0-9]{4,}"                     | grep -cv "^rep" 2>/dev/null || echo 0)
                [[ "$_dtc" -eq 0 ]] && local_match=1
            fi
            [[ $local_match -eq 0 ]] && continue

            # Cross-check: no significant job token absent from dir name
            _skip=0
            while IFS= read -r _jtok; do
                [[ ${#_jtok} -lt 3 ]] && continue
                echo "general memb prod step charmm gromacs amber" | grep -qi "$_jtok" && continue
                echo "$_bname_lower" | grep -qi "$_jtok" || { _skip=1; break; }
            done < <(echo "$_jname" | grep -oP "[a-z0-9]{3,}")
            [[ $_skip -eq 1 ]] && continue

            # Match found — add to SIM_DIRS
            SIM_DIRS+=("$_subdir")
            _discovered["$_subdir"]=1
        done < <(find "$ROOT_DIR" "${depth_args[@]}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done
    unset _discovered _jid _jname _jrep _subdir _bname _bname_lower _drep _tok _jtok _skip local_match
fi

if [[ ${#SIM_DIRS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}  No GROMACS simulation directories found under '${ROOT_DIR}'.${RESET}"
    exit 0
fi

COUNT=${#SIM_DIRS[@]}
PLURAL="$([[ $COUNT -eq 1 ]] && echo "directory" || echo "directories")"
echo -e "  Found ${BOLD}${COUNT}${RESET} simulation ${PLURAL}."
echo

# ── Table layout ─────────────────────────────────────────────────────────────
# Visible column widths (ANSI escape bytes are NOT counted here).
CW_PATH=48
CW_STAT=13   # "FINISHED   ✔" = 13 visible chars
CW_JOB=14   # "1625344 (PD)" = 12 chars + margin
CW_TIME=14
CW_FRM=12
CW_DSK=8
CW_ATM=6

# ansi_pad WIDTH STRING
# Writes STRING to stdout, then appends spaces until visible width = WIDTH.
# Needed because printf %-Ns counts invisible ANSI escape bytes as characters.
ansi_pad() {
    local w=$1 s=$2
    local vis
    vis=$(printf '%b' "$s" | sed 's/\x1b\[[0-9;]*m//g')
    printf '%b' "$s"
    local pad=$(( w - ${#vis} ))
    (( pad > 0 )) && printf '%*s' "$pad" ""
}

# ── Table header ──────────────────────────────────────────────────────────────
printf "${BOLD}  %-${CW_PATH}s  %-${CW_STAT}s  %-${CW_JOB}s  %-${CW_TIME}s  %-${CW_FRM}s  %-${CW_DSK}s  %-${CW_ATM}s  %s${RESET}\n" \
    "PATH (relative)" "STATUS" "JOB ID" "SIM TIME" "STEPS" "DISK" "ATOMS" \
    "FILES (tpr log xtc cpt edr gro)"
SEP="  $(printf '%.0s─' $(seq 1 $CW_PATH))  $(printf '%.0s─' $(seq 1 $CW_STAT))  $(printf '%.0s─' $(seq 1 $CW_JOB))  $(printf '%.0s─' $(seq 1 $CW_TIME))  $(printf '%.0s─' $(seq 1 $CW_FRM))  $(printf '%.0s─' $(seq 1 $CW_DSK))  $(printf '%.0s─' $(seq 1 $CW_ATM))  $(printf '%.0s─' {1..36})"
echo -e "${DIM}${SEP}${RESET}"

declare -i total=0 n_fin=0 n_run=0 n_fail=0 n_inc=0 n_queued=0 n_other=0
declare -a FAILED_DETAILS=()

for sim_dir in "${SIM_DIRS[@]}"; do
    rel="$(rel_path "$sim_dir")"
    raw="$(classify_sim "$sim_dir")"
    main_line="$(echo "$raw" | grep -v '^VERBOSE|' | head -1)"
    verbose_line="$(echo "$raw" | grep '^VERBOSE|' || true)"

    IFS='|' read -r status gmx_enc mpi_enc gen_err perf_enc progress \
                     steps time_ps job_id atoms disk \
                     has_tpr has_log has_xtc has_cpt has_edr has_confout \
                     <<< "$main_line"

    total+=1
    case "$status" in
        FINISHED)    n_fin+=1       ;;
        RUNNING)     n_run+=1       ;;
        FAILED)      n_fail+=1      ;;
        INCOMPLETE)  n_inc+=1       ;;
        QUEUED)      n_queued+=1    ;;
        *)           n_other+=1     ;;
    esac

    [[ $ERRORS_ONLY -eq 1 && "$status" != "FAILED" && "$status" != "INCOMPLETE" && "$status" != "QUEUED" ]] && continue

    disp_rel="$rel"
    (( ${#disp_rel} > CW_PATH )) && disp_rel="...${disp_rel: -$((CW_PATH-3))}"

    sim_time="$(convert_time "$time_ps")"
    files_col="$(files_column "$has_tpr" "$has_log" "$has_xtc" "$has_cpt" "$has_edr" "$has_confout")"
    disp_disk="$([[ $SHOW_DISK -eq 1 ]] && echo "$disk" || echo "-")"
    # Format atoms: add 'k' suffix for thousands
    disp_atoms="-"
    if [[ "$atoms" != "-" && "$atoms" =~ ^[0-9]+$ ]]; then
        disp_atoms=$(awk -v n="$atoms" 'BEGIN{if(n>=1000)printf "%.0fk",n/1000; else printf "%d",n}')
    fi

    # Print one table row — use ansi_pad() for the colored STATUS field
    # so that invisible ANSI bytes don't shift subsequent columns.
    printf "  %-${CW_PATH}s  " "$disp_rel"
    ansi_pad $CW_STAT "$(status_label "$status")"
    printf "  %-${CW_JOB}s  %-${CW_TIME}s  %-${CW_FRM}s  %-${CW_DSK}s  %-${CW_ATM}s  " \
        "$job_id" "$sim_time" "$steps" "$disp_disk" "$disp_atoms"
    printf "%b\n" "$files_col"

    # ── Sub-rows: errors (FAILED) ────────────────────────────────────────────
    if [[ "$status" == "FAILED" ]]; then
        print_block "$gmx_enc" "$RED"    "GROMACS" "├"
        print_block "$mpi_enc" "$ORANGE" "MPI/PAR" "├"
        if [[ "$gen_err" != "-" ]]; then
            gen_first="${gen_err%%^*}"
            gmx_first="${gmx_enc%%^*}"
            mpi_first="${mpi_enc%%^*}"
            if [[ "$gen_first" != "$gmx_first" && "$gen_first" != "$mpi_first" ]]; then
                print_block "$gen_err" "$YELLOW" "OTHER  " "└"
            fi
        fi
    fi

    # ── Sub-rows: post-processing notes (FINISHED with script errors) ──────────
    if [[ "$status" == "FINISHED" && "$gen_err" != "-" && "$gmx_enc" == "-" && "$mpi_enc" == "-" ]]; then
        print_block "$gen_err" "$DIM" "NOTE   " "└"
    fi

    # ── Sub-rows: performance (FINISHED and FINALIZED) ────────────────────────
    if [[ "$status" == "FINISHED" && "$perf_enc" != "-" ]]; then
        print_block "$perf_enc" "$GREEN" "PERF  " "└"
    fi

    # ── Sub-row: progress (RUNNING / INCOMPLETE) ──────────────────────────────
    if [[ -n "$progress" && "$progress" != "-" && \
          ( "$status" == "RUNNING" || "$status" == "INCOMPLETE" ) ]]; then
        echo -e "    ${CYAN}└ PROGRS ${RESET} ${DIM}${progress}${RESET}"
    fi

    [[ $VERBOSE -eq 1 && -n "$verbose_line" ]] && \
        echo -e "${DIM}    └ files: ${verbose_line#VERBOSE|}${RESET}"

    [[ "$status" == "FAILED" ]] && \
        FAILED_DETAILS+=("${rel}|JOB:${job_id}|${gmx_enc}|${mpi_enc}|${gen_err}|${sim_dir}")
done

echo -e "${DIM}${SEP}${RESET}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}  ┌─ SUMMARY ────────────────────────────────────────┐${RESET}"
printf  "  │  %-30s  %5d                │\n" "Total simulation dirs:"  "$total"
printf  "  │  %-30s  " "Finished:";   printf "${GREEN}%5d${RESET}                │\n" "$n_fin"
  printf  "  │  %-30s  " "Running:";    printf "${CYAN}%5d${RESET}                │\n"  "$n_run"
  printf  "  │  %-30s  " "Queued:";     printf "${BLUE}%5d${RESET}                │\n"  "$n_queued"
  printf  "  │  %-30s  " "Incomplete:"; printf "${YELLOW}%5d${RESET}                │\n" "$n_inc"
  printf  "  │  %-30s  " "Failed:";     printf "${RED}%5d${RESET}                │\n"   "$n_fail"
  printf  "  │  %-30s  %5d                │\n" "Other / Unknown:"        "$n_other"
echo -e "${BOLD}  └──────────────────────────────────────────────────┘${RESET}"

# ── Legend ────────────────────────────────────────────────────────────────────
echo
echo -e "  ${DIM}── Legend ───────────────────────────────────────────────────────────────${RESET}"
echo -e "  ${GREEN}FINISHED${RESET}    confout.gro present OR 'Finished mdrun' in log"
echo -e "  ${CYAN}RUNNING${RESET}     *.cpt modified <60 min ago"
echo -e "  ${YELLOW}INCOMPLETE${RESET}  *.cpt/*.edr found, no clean finish, no SLURM error"
echo -e "  ${RED}FAILED${RESET}      Error found in SLURM *.err.<jobid>"
echo -e "  ${DIM}NOT_STARTED${RESET} *.tpr present but no outputs yet"
echo -e "  ${MAGENTA}NO_TPR${RESET}      No *.tpr found"
echo -e "  ${DIM}Sub-rows:  ${RED}GROMACS${RESET}${DIM} gmx fatal block  ${ORANGE}MPI/PAR${RESET}${DIM} mpi_abort/prterun  ${YELLOW}OTHER${RESET}${DIM} sbatch/I-O${RESET}"
echo -e "  ${DIM}           ${GREEN}PERF${RESET}${DIM} ns/day hours/ns wall time (FINISHED only)${RESET}"
echo -e "  ${DIM}           ${CYAN}PROGRS${RESET}${DIM} last step from SLURM .out (RUNNING/INCOMPLETE)${RESET}"
echo -e "  ${DIM}Key flags: -p PATTERN · --slurm-prefix PFX · --dt PS · --err-lines N${RESET}"
echo -e "  ${DIM}           --time-unit ps|ns|us · --no-disk · --errors-only · --no-color${RESET}"
echo -e "  ${DIM}Full FAILED detail → ${LOGFILE}${RESET}"
echo

# ══════════════════════════════════════════════════════════════════════════════
#  FAILED DETAIL — log file ONLY (fd 3)
# ══════════════════════════════════════════════════════════════════════════════
{
    echo ""
    echo "══ FAILED SIMULATIONS — FULL DETAIL (log only) ═════════════════════"
    if [[ ${#FAILED_DETAILS[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        for entry in "${FAILED_DETAILS[@]}"; do
            IFS='|' read -r path job gmx_e mpi_e gen_e abs_dir <<< "$entry"
            echo "  ✖ ${path}  [${job}]"
            if [[ "$gmx_e" != "-" ]]; then
                echo "    ── GROMACS error ──"
                echo "$gmx_e" | tr '^' '\n' | sed 's/^/    /'
            fi
            if [[ "$mpi_e" != "-" ]]; then
                echo "    ── MPI/PAR error ──"
                echo "$mpi_e" | tr '^' '\n' | sed 's/^/    /'
            fi
            if [[ "$gen_e" != "-" ]]; then
                local gf="${gen_e%%^*}" gxf="${gmx_e%%^*}" mf="${mpi_e%%^*}"
                if [[ "$gf" != "$gxf" && "$gf" != "$mf" ]]; then
                    echo "    ── OTHER ──"
                    echo "$gen_e" | tr '^' '\n' | sed 's/^/    /'
                fi
            fi
            local_err="$(latest_slurm_file "$abs_dir" "err")"
            if [[ -n "$local_err" && -f "$local_err" ]]; then
                echo "    ── full content of $(basename "$local_err") ──"
                sed 's/^/    /' < "$local_err"
            fi
            echo ""
        done
    fi
} >&3
exec 3>&-
