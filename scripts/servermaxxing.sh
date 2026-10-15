#!/usr/bin/env bash
# servermaxxing: tune a Linux box (laptop, bare metal, VPS) for 24/7 autonomous coding agents.
#
# In an interactive terminal it draws a single-screen status board that updates in place.
# Anywhere else (pipes, CI, cloud-init, AI agents) it prints one logfmt line per event, no ANSI.
# `--help` lists the options.
#
# One file on purpose: the README and ../servermaxxing.sh fetch only this one. Past the constants
# below, everything is a function definition and the only call is `main "$@"` on the last line, so
# bash has read the whole file before anything runs: a truncated `curl | bash` download runs
# nothing, and no child process can swallow the rest of the script from stdin.
# shellcheck disable=SC1007  # `var= other=x` empty assignments are intentional
set -Eeuo pipefail
shopt -s extglob
export DEBIAN_FRONTEND=noninteractive

REPO_RAW="https://raw.githubusercontent.com/kshanxs/servermaxxing/main"
AGENTS="claude codex herdr tuios"
CLI_PACKAGES=(ripgrep fd-find fzf ncdu tree tmux jq btop htop fastfetch zram-tools)
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
AUDIT_PROMPT="Review and audit this machine against servermaxxing standards. Check sleep masking, battery caps, ZRAM swap, Docker, and Tailscale."

# One entry per board row, as parallel arrays indexed by row number.
T_ID=() T_LABEL=() T_KIND=() T_DEPS=() T_TIMEOUT=() T_STATE=() T_DETAIL=() T_T0=() T_T1=() T_RC=()
declare -A T_IDX=() CALLER=()
EXTRAS=() NEXT=()
CUR=-1 CUR_ID= PID= TAIL_PID= DRAWN=0 FRAME=0 RESIZED=0 STALL_SIZE=-1 STALL_T=0 PHASE=start
INTERRUPTED=0 FINISHED=0 TERM_DIRTY=0 STTY_SAVED= ERR_INFO= LAUNCH=0 LAUNCH_ABORT=0

# ── 1. arguments ───────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
servermaxxing: tune a Linux box for 24/7 autonomous coding agents

usage: sudo bash servermaxxing.sh [options]
       curl -fsSL $REPO_RAW/scripts/servermaxxing.sh | sudo bash -s -- [options]

  -a, --agent NAME  install NAME if needed and launch it when done: ${AGENTS// /, }
      --check       audit only: show what is already in place, change nothing
      --ui MODE     auto (default), live (in-place board) or plain (one logfmt line per event)
  -v, --verbose     plain mode: also stream every step's raw output
      --no-launch   never hand off to the agent, even in an interactive terminal
      --demo        preview the UI with simulated steps; changes nothing, needs no root
  -h, --help        show this help

environment: SERVERMAXXING_AGENT, SERVERMAXXING_UI, TAILSCALE_AUTHKEY, NO_COLOR
exit status: 0 done (warnings allowed), 1 a required step failed or --check found drift,
             2 bad usage, 130 interrupted
EOF
}

die_usage() { printf 'servermaxxing: %s\n\n' "$1" >&2; usage >&2; exit 2; }
die() { printf 'servermaxxing: %s\n' "$1" >&2; exit 1; }

parse_args() {
    AGENT_CHOICE=${SERVERMAXXING_AGENT:-}
    # The legacy AGENT variable only counts when it names one of our agents: harnesses following
    # the agents.md proposal export AGENT=<their own name> (goose, amp, ...).
    if [[ -z $AGENT_CHOICE && -n ${AGENT:-} && " $AGENTS " == *" $AGENT "* ]]; then AGENT_CHOICE=$AGENT; fi
    UI_MODE=${SERVERMAXXING_UI:-auto} CHECK_ONLY=0 VERBOSE=0 NO_LAUNCH=0 DEMO=0
    while (($#)); do
        case $1 in
            -a|--agent) (($# >= 2)) || die_usage "$1 needs a value"; AGENT_CHOICE=$2; shift ;;
            --agent=*) AGENT_CHOICE=${1#*=} ;;
            --ui) (($# >= 2)) || die_usage "$1 needs a value"; UI_MODE=$2; shift ;;
            --ui=*) UI_MODE=${1#*=} ;;
            --check) CHECK_ONLY=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            --no-launch) NO_LAUNCH=1 ;;
            --demo) DEMO=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown option: $1" ;;
        esac
        shift
    done
    if [[ $AGENT_CHOICE == none ]]; then AGENT_CHOICE=; fi
    if [[ -n $AGENT_CHOICE && " $AGENTS " != *" $AGENT_CHOICE "* ]]; then
        die_usage "unknown agent '$AGENT_CHOICE' (choose from: $AGENTS)"
    fi
    case $UI_MODE in auto|live|plain) ;; *) die_usage "--ui must be auto, live or plain" ;; esac
}

# ── 2. context: who is running us, and what the terminal can do ───────────────

caller_env() {
    # sudo's env_reset strips CI, CLAUDECODE, NO_COLOR & co. from our environment, but the sudo
    # process itself still carries the caller's, so read it from our ancestors in /proc.
    local pid=$$ _
    for _ in 1 2 3 4; do
        pid=$(awk '$1 == "PPid:" { print $2 }' "/proc/$pid/status" 2>/dev/null) || return 0
        if [[ -z $pid || $pid -le 1 ]]; then return 0; fi
        tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" || true
    done
}

detect_context() {
    local line v ci
    while IFS= read -r line; do
        v=${line%%=*}
        if [[ $line == *=* && $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -z ${CALLER[$v]+set} ]]; then CALLER[$v]=${line#*=}; fi
    done < <(caller_env)

    # Markers set by agent harnesses (list from @vercel/detect-agent and the is-ai-agent crate).
    # Most harnesses pipe stdout, which the TTY test below catches anyway; these cover the ones
    # that run commands inside a pty (OpenHands uses tmux, for one).
    IN_AGENT=
    for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX CODEX_THREAD_ID CODEX_CI GEMINI_CLI CURSOR_AGENT \
             OPENCODE GOOSE_TERMINAL AMP_CURRENT_THREAD_ID AUGMENT_AGENT COPILOT_AGENT REPL_ID AI_AGENT; do
        if [[ -n ${!v:-}${CALLER[$v]:-} ]]; then IN_AGENT=$v; break; fi
    done
    if [[ -z $IN_AGENT && ${PS1:-}${CALLER[PS1]:-}${CALLER[PROMPT_COMMAND]:-} == *'###PS1JSON###'* ]]; then IN_AGENT=OPENHANDS; fi

    HEADLESS=   # set when nobody is there to answer a prompt or take over the terminal
    ci=${CI:-${CALLER[CI]:-}}
    if [[ -n $ci && $ci != false && $ci != 0 ]]; then HEADLESS=ci
    elif [[ -n $IN_AGENT ]]; then HEADLESS=agent:$IN_AGENT
    fi

    TTY_OK=0
    if { : </dev/tty; } 2>/dev/null; then TTY_OK=1; fi
    read_size
    if [[ $UI_MODE == auto ]]; then
        UI_MODE=plain
        # The board needs a real terminal that is big enough: cursor-up cannot reach past row 1.
        if [[ -t 1 && ${TERM:-dumb} != dumb && -z $HEADLESS ]] && ((COLS >= 60 && ROWS >= ${#T_ID[@]} + 6)); then
            UI_MODE=live
        fi
    fi
}

read_size() {
    local s
    s=$(stty size 2>/dev/null </dev/tty) || s=
    ROWS=${s%% *} COLS=${s##* }
    if [[ ! $ROWS =~ ^[1-9][0-9]*$ ]]; then ROWS=24; fi   # ptys can report "0 0"
    if [[ ! $COLS =~ ^[1-9][0-9]*$ ]]; then COLS=80; fi
}

setup_style() {
    local charmap
    charmap=$(locale charmap 2>/dev/null) || charmap=
    if [[ $charmap == UTF-8 ]]; then
        G_PEND='·' G_SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' G_DONE='✓' G_HAVE='●' G_NA='–' G_WARN='!' G_FAIL='✗'
        G_RULE='─' G_TICK='›' G_DOT='·' G_ELL='…' G_BAR='│'
    else
        G_PEND='.' G_SPIN='|/-\' G_DONE='+' G_HAVE='=' G_NA='-' G_WARN='!' G_FAIL='x'
        G_RULE='-' G_TICK='>' G_DOT='|' G_ELL='~' G_BAR='|'
    fi
    C_0= C_B= C_DIM= C_RED= C_GRN= C_YEL= C_CYN= C_DGRN=
    if [[ $UI_MODE == live && -z ${NO_COLOR:-}${CALLER[NO_COLOR]:-} ]]; then
        C_0=$'\e[0m' C_B=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m'
        C_CYN=$'\e[36m' C_DGRN=$'\e[2;32m'
    fi
    layout
}

layout() {
    BOARD_W=$((COLS - 1 < 80 ? COLS - 1 : 80))
    printf -v RULE '%*s' $((BOARD_W - 2)) ''
    RULE=${RULE// /$G_RULE}
}

# ── 3. ui ──────────────────────────────────────────────────────────────────────
# Live mode draws an inline region and redraws it with cursor moves relative to the lines it drew
# itself: no alternate screen (the final board and any errors stay in scrollback) and no terminfo
# (fresh servers often lack entries for xterm-ghostty, xterm-kitty and friends).

term_setup() {
    if [[ $UI_MODE != live ]]; then return 0; fi
    if ((TTY_OK)); then
        STTY_SAVED=$(stty -g 2>/dev/null </dev/tty) || STTY_SAVED=
        stty -echo 2>/dev/null </dev/tty || true   # keystrokes would smear the board; isig stays on
    fi
    TERM_DIRTY=1
    printf '\e[?25l\e[?7l'   # hide the cursor; no autowrap, since one wrapped line breaks the redraw math
}

term_restore() {
    if ((!TERM_DIRTY)); then return 0; fi
    TERM_DIRTY=0
    printf '\e[?2026l\e[0m\e[?7h\e[?25h'
    if [[ -n $STTY_SAVED ]]; then stty "$STTY_SAVED" 2>/dev/null </dev/tty || true; fi
}

fit() {  # fit <text> <width> [pad]: cut to width in characters, not bytes; sets FIT
    local s=$1 w=$2
    if ((w < 1)); then FIT=; return 0; fi
    if ((${#s} > w)); then s=${s:0:w-1}$G_ELL; fi
    if [[ ${3:-} == pad ]] && ((${#s} < w)); then printf -v s '%s%*s' "$s" $((w - ${#s})) ''; fi
    FIT=$s
}

fmt_dur() { printf -v DUR '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

clean() {  # strip what would corrupt a fixed-width line: \r redraws, ANSI codes, control chars; sets CLEAN
    local s=$1
    s=${s%%+($'\r')}
    s=${s##*$'\r'}
    s=${s//$'\e'\[*([0-9;?])[A-Za-z]/}
    CLEAN=${s//[^[:print:]]/ }
}

q() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }   # logfmt-quote a value

join_dot() { local out= x; for x in "$@"; do out+=${out:+ $G_DOT }$x; done; printf '%s\n' "$out"; }

render() {  # one frame, one write
    if [[ $UI_MODE != live ]]; then return 0; fi
    local final=${1:-0} f=$'\e[?2026h' i n=0
    if ((RESIZED)); then RESIZED=0; read_size; layout; fi
    if ((DRAWN)); then f+=$'\e['"$DRAWN"$'A\r'; fi
    FRAME=$((FRAME + 1))
    fit "$HEADER" $((BOARD_W - 15))
    f+=$'\e[2K'"  ${C_B}servermaxxing${C_0}${C_DIM}${FIT}${C_0}"$'\n'
    f+=$'\e[2K'"  ${C_DIM}${RULE}${C_0}"$'\n'
    n=2
    for i in "${!T_ID[@]}"; do
        row "$i"
        f+=$'\e[2K'"$ROW"$'\n'
        n=$((n + 1))
    done
    f+=$'\e[2K'"  ${C_DIM}${RULE}${C_0}"$'\n'
    n=$((n + 1))
    if ((final)); then
        f+=$'\e[J'   # the final frame drops the ticker line
    else
        ticker
        f+=$'\e[2K'"$TICK"$'\n'
        n=$((n + 1))
    fi
    f+=$'\e[?2026l'
    printf '%s' "$f"
    DRAWN=$n
}

row() {  # sets ROW for board row <i>
    local i=$1 g c dc=$C_DIM lc= det=${T_DETAIL[$1]} tim= dw lab
    case ${T_STATE[i]} in
        pending) g=$G_PEND c=$C_DIM ;;
        running) g=${G_SPIN:FRAME % ${#G_SPIN}:1} c=$C_CYN dc= lc=$C_B; live_detail "$i"; det=$LIVE_DETAIL ;;
        done) g=$G_DONE c=$C_GRN ;;
        present) g=$G_HAVE c=$C_DGRN ;;
        na|blocked) g=$G_NA c=$C_DIM ;;
        warn) g=$G_WARN c=$C_YEL dc=$C_YEL ;;
        fail) g=$G_FAIL c=$C_RED dc=$C_RED ;;
    esac
    if [[ ${T_STATE[i]} == running ]]; then
        fmt_dur $((SECONDS - T_T0[i])); tim=$DUR
    elif [[ -n ${T_T1[i]} ]] && ((T_T1[i] - T_T0[i] >= 2)); then
        fmt_dur $((T_T1[i] - T_T0[i])); tim=$DUR
    fi
    dw=$((BOARD_W - 16))
    if [[ -n $tim ]]; then dw=$((dw - 2 - ${#tim})); fi
    fit "$det" "$dw" ${tim:+pad}
    printf -v lab '%-10s' "${T_LABEL[i]}"
    ROW="  ${c}${g}${C_0}  ${lc}${lab}${C_0} ${dc}${FIT}${C_0}"
    if [[ -n $tim ]]; then ROW+="  ${C_DIM}${tim}${C_0}"; fi
}

live_detail() {  # what a running step is doing: apt's own progress if newer, else the step's last `say`
    local id=${T_ID[$1]} l k _p pct desc
    LIVE_DETAIL=${T_DETAIL[$1]}
    if [[ -s $RUN/$id.status ]]; then
        while IFS= read -r l; do
            if [[ $l != @(WARN|NEXT):* ]]; then LIVE_DETAIL=$l; fi
        done <"$RUN/$id.status"
    fi
    if [[ -s $RUN/$id.progress && $RUN/$id.progress -nt $RUN/$id.status ]]; then
        l=$(tail -n 1 "$RUN/$id.progress" 2>/dev/null) || l=
        IFS=: read -r k _p pct desc <<<"$l" || true
        case $k in pmstatus|dlstatus) LIVE_DETAIL="${pct%%.*}% $G_DOT ${desc,}" ;; esac
    fi
}

ticker() {  # sets TICK: the newest line of the running step's log, or a stall warning
    local t= pre="$G_TICK " pc=$C_DIM quiet
    if [[ $PHASE == preflight ]]; then
        t="checking what is already in place"
    elif ((CUR >= 0)) && [[ ${T_STATE[CUR]} == running ]]; then
        t=$(tail -n 1 "$RUN/${T_ID[CUR]}.log" 2>/dev/null) || t=
        clean "$t"; t=$CLEAN
        quiet=$((SECONDS - STALL_T))
        if ((quiet >= 30)); then pre="$G_TICK no output for ${quiet}s $G_DOT " pc=$C_YEL; fi
    fi
    fit "$pre$t" $((COLS - 3))
    TICK="  ${pc}${FIT}${C_0}"
}

emit() {  # emit <step> <status> [detail] [k=v...]: one logfmt event, always to events.log, to stdout in plain mode
    local line="servermaxxing t=$((SECONDS - T_START))s step=$1 status=$2"
    if (($# > 3)); then line+=" ${*:4}"; fi
    if [[ -n ${3:-} ]]; then line+=" detail=$(q "$3")"; fi
    printf '%s\n' "$line" >>"$EVENTS"
    if [[ $UI_MODE == plain ]]; then printf '%s\n' "$line"; fi
}

fail_reason() {  # the most telling line of a step's log: its last error-looking line, else its last line
    local l last= err=
    while IFS= read -r l; do
        clean "$l"; l=${CLEAN##+([[:space:]])}
        if [[ -z $l || $l == @('==> '|'WARN: ')* ]]; then continue; fi
        last=$l
        if [[ ${l,,} =~ ^e:|error|fatal|denied|failed|could\ not|unable\ to|timed\ out|not\ found ]]; then err=$l; fi
    done < <(tail -n 80 "$1" 2>/dev/null)
    printf '%s' "${err:-$last}"
}

hint_for() {  # a plain-language next step for well-known failures in a log
    local f=$1
    if grep -qs -e 'Could not get lock' -e 'Unable to acquire the dpkg' "$f"; then
        echo "another apt/dpkg process held the lock (often unattended-upgrades on first boot); re-run in a few minutes"
    elif grep -qsi -e 'Temporary failure resolving' -e 'Could not resolve host' -e 'Name or service not known' "$f"; then
        echo "DNS or network is unreachable: check connectivity and /etc/resolv.conf"
    elif grep -qsi -e 'rate limit' -e 'returned error: 403' -e 'returned error: 429' "$f"; then
        echo "GitHub API rate limit: wait a while and re-run"
    elif grep -qs -e 'Unable to locate package' -e 'has no installation candidate' "$f"; then
        echo "package is not in this release's archive"
    elif grep -qsi 'No space left on device' "$f"; then
        echo "disk is full: free some space and re-run"
    elif grep -qs 'dpkg was interrupted' "$f"; then
        echo "dpkg was interrupted: re-run servermaxxing, it repairs this first"
    elif grep -qsi -e 'timed out' -e 'Connection reset' "$f"; then
        echo "network timeout: re-run, or check outbound HTTPS"
    elif grep -qsi 'certificate' "$f"; then
        echo "TLS certificate problem: check the system clock and ca-certificates"
    fi
    return 0
}

explain() {  # explain <row> <lines>: the evidence for a failed step, straight from its log
    local i=$1 n=$2 id=${T_ID[$1]} l h pre="     $G_BAR " w
    local log=$RUN/$id.log
    if [[ $UI_MODE == plain ]]; then pre="  | "; fi
    w=$((COLS - ${#pre} - 1))
    if [[ -s $RUN/$id.status ]]; then
        while IFS= read -r l; do
            if [[ $l == WARN:* ]]; then printf '%s%s%snote%s %s\n' "$C_DIM" "$pre" "$C_YEL" "$C_0" "${l#WARN:}"; fi
        done <"$RUN/$id.status"
    fi
    if ((n > 0)); then
        while IFS= read -r l; do
            clean "$l"; l=$CLEAN
            if [[ $UI_MODE == live ]]; then fit "$l" "$w"; l=$FIT; fi
            printf '%s%s%s%s\n' "$C_DIM" "$pre" "$l" "$C_0"
        done < <(grep -v -e '^==> ' -e '^WARN: ' "$log" 2>/dev/null | tail -n "$n")
    fi
    h=$(hint_for "$log")
    if [[ -n $h ]]; then printf '%s%shint%s %s\n' "$pre" "$C_YEL" "$C_0" "$h"; fi
    printf '%s%slog%s  %s\n' "$pre" "$C_DIM" "$C_0" "$log"
}

summary() {
    local i k c g head n_done=0 n_present=0 n_na=0 n_pending=0 n_warn=0 n_fail=0 n_blocked=0 result
    for i in "${!T_ID[@]}"; do
        case ${T_STATE[i]} in
            done) n_done=$((n_done + 1)) ;; present) n_present=$((n_present + 1)) ;;
            na) n_na=$((n_na + 1)) ;; pending) n_pending=$((n_pending + 1)) ;;
            warn) n_warn=$((n_warn + 1)) ;; fail) n_fail=$((n_fail + 1)) ;;
            blocked) n_blocked=$((n_blocked + 1)) ;;
        esac
    done
    fmt_dur $((SECONDS - T_START))
    if ((CHECK_ONLY)); then
        result=ok; if ((n_pending)); then result=drift; fi
    else
        result=ok; if ((n_fail || n_blocked)); then result=failed; fi
    fi

    if [[ $UI_MODE == plain ]]; then
        printf -v k 'servermaxxing result=%s changed=%d present=%d na=%d pending=%d warn=%d failed=%d blocked=%d duration=%ds log=%s' \
            "$result" "$n_done" "$n_present" "$n_na" "$n_pending" "$n_warn" "$n_fail" "$n_blocked" $((SECONDS - T_START)) "$RUN"
        printf '%s\n' "$k" | tee -a "$EVENTS"
        for k in "${NEXT[@]}"; do printf 'servermaxxing next=%s\n' "$(q "$k")" | tee -a "$EVENTS"; done
        return 0
    fi

    if ((CHECK_ONLY)); then
        head="$n_present in place $G_DOT $n_pending to change $G_DOT $n_na not applicable $G_DOT nothing was changed"
        c=$C_GRN g=$G_DONE
        if ((n_pending)); then c=$C_YEL g=$G_WARN; NEXT+=("apply: run again without --check"); fi
    else
        head="done in $DUR $G_DOT $n_done changed $G_DOT $n_present already in place"
        c=$C_GRN g=$G_DONE
        if ((n_warn == 1)); then head+=" $G_DOT 1 warning"; c=$C_YEL g=$G_WARN; fi
        if ((n_warn > 1)); then head+=" $G_DOT $n_warn warnings"; c=$C_YEL g=$G_WARN; fi
        if ((n_fail || n_blocked)); then
            head="failed after $DUR $G_DOT $n_fail failed $G_DOT $n_blocked blocked $G_DOT $n_done changed"
            c=$C_RED g=$G_FAIL
        fi
    fi
    printf '  %s%s %s%s\n' "$c" "$g" "$head" "$C_0"
    for i in "${!T_ID[@]}"; do
        case ${T_STATE[i]} in
            fail) printf '\n  %s%s  %-10s%s %s\n' "$C_RED" "$G_FAIL" "${T_LABEL[i]}" "$C_0" "${T_DETAIL[i]}"; explain "$i" 8 ;;
            warn)
                printf '\n  %s%s  %-10s%s %s\n' "$C_YEL" "$G_WARN" "${T_LABEL[i]}" "$C_0" "${T_DETAIL[i]}"
                if [[ ${T_RC[i]} != 0 ]]; then explain "$i" 3; fi ;;   # rc 0: it worked, with a note
        esac
    done
    if ((${#NEXT[@]})); then printf '\n'; fi
    for k in "${NEXT[@]}"; do printf '  %snext%s  %s\n' "$C_CYN" "$C_0" "$k"; done
    printf '  %slog%s   %s\n' "$C_DIM" "$C_0" "$RUN"
}

# ── 4. runner ──────────────────────────────────────────────────────────────────

task() {  # task <id> <label> <required|optional> <timeout seconds> [depends on...]
    local i=${#T_ID[@]}
    T_IDX[$1]=$i T_ID[i]=$1 T_LABEL[i]=$2 T_KIND[i]=$3 T_TIMEOUT[i]=$4
    shift 4
    T_DEPS[i]="$*" T_STATE[i]=pending T_DETAIL[i]= T_T0[i]= T_T1[i]= T_RC[i]=
}

register_tasks() {
    local t agent=$AGENT_CHOICE
    if [[ -z $agent ]] && ((DEMO)); then agent=claude; fi
    for t in superfile herdr tuios speedtest neofetch; do
        if [[ $t != "$AGENT_CHOICE" ]]; then EXTRAS+=("$t"); fi
    done
    if ((!DEMO)) && dpkg_interrupted; then task repair repair required 900; fi
    task power power required 120
    task debloat debloat optional 120
    task snaps snaps optional 600
    task apt apt required 1800
    task zram zram optional 120 apt
    task uv uv required 600
    task node node required 900 apt
    task vp "vite+" optional 900
    case $agent in
        claude|codex) task agent "$agent" required 900 node ;;
        herdr|tuios) task agent "$agent" required 600 ;;
    esac
    task docker docker required 1200
    task tailscale tailscale required 600
    task extras extras optional 1200
    task sudoers sudoers required 60
}

step() {  # step check|run <id>: the real step function, or its --demo stand-in
    if ((DEMO)); then "demo_$1" "$2"; else "$1_$2"; fi
}

preflight() {  # local probes only, so the whole board is filled in before the first network request
    local i rc out
    PHASE=preflight
    render
    for i in "${!T_ID[@]}"; do
        rc=0
        out=$(step check "${T_ID[i]}" 2>/dev/null) || rc=$?
        case $rc in 0) T_STATE[i]=present ;; 2) T_STATE[i]=na ;; *) T_STATE[i]=pending ;; esac
        T_DETAIL[i]=$out
        emit "${T_ID[i]}" "${T_STATE[i]}" "$out"
        render
    done
    PHASE=run
}

run_all() {
    local i d j
    for i in "${!T_ID[@]}"; do
        if [[ ${T_STATE[i]} != pending ]]; then continue; fi
        for d in ${T_DEPS[i]}; do
            j=${T_IDX[$d]:-}
            if [[ -n $j && ${T_STATE[j]} == @(fail|blocked) ]]; then
                T_STATE[i]=blocked T_DETAIL[i]="blocked by $d"
                emit "${T_ID[i]}" blocked "${T_DETAIL[i]}"
                render
                continue 2
            fi
        done
        run_task "$i"
    done
}

run_task() {
    # Never call this from an if/||/&& context: bash would then silently switch off errexit inside
    # the step body, even in the background subshell, and a failed command would go unnoticed.
    local i=$1 id=${T_ID[$1]} rc=0 timed_out=0 last=-1 sz
    local log=$RUN/$id.log
    CUR=$i T_STATE[i]=running T_T0[i]=$SECONDS STALL_SIZE=-1 STALL_T=$SECONDS
    : >"$RUN/$id.status"
    printf '==> %s  %s\n' "$(date -u +%FT%TZ)" "${T_LABEL[i]}" >>"$log"
    emit "$id" start
    set -m   # the step gets its own process group, so stop_job can take down apt, dpkg, curl and all
    ( trap - ERR; CUR_ID=$id; step run "$id" ) </dev/null >>"$log" 2>&1 &
    PID=$!
    set +m
    if [[ $UI_MODE == plain ]] && ((VERBOSE)); then
        tail -s 0.2 -n +1 -f --pid="$PID" "$log" 2>/dev/null | sed -u "s/^/  [$id] /" &
        TAIL_PID=$!
    fi
    while kill -0 "$PID" 2>/dev/null; do
        if ((SECONDS - T_T0[i] >= T_TIMEOUT[i])); then timed_out=1; stop_job; break; fi
        if ((SECONDS != last)); then   # stall watch, once a second
            last=$SECONDS
            sz=$(wc -c 2>/dev/null <"$log") || sz=0
            if ((sz != STALL_SIZE)); then STALL_SIZE=$sz STALL_T=$SECONDS; fi
        fi
        render
        sleep 0.1
    done
    if ((timed_out)); then rc=124; else wait "$PID" || rc=$?; fi
    PID=
    if [[ -n $TAIL_PID ]]; then wait "$TAIL_PID" 2>/dev/null || true; TAIL_PID=; fi
    finish_task "$i" "$rc" "$timed_out"
    CUR=-1
    render
}

finish_task() {  # finish_task <row> <exit status> <timed out>: a step passes only if it exits 0 AND its check passes
    local i=$1 rc=$2 id=${T_ID[$1]} out crc=0 warns= l reason
    T_T1[i]=$SECONDS T_RC[i]=$rc
    if [[ -s $RUN/$id.status ]]; then
        while IFS= read -r l; do
            case $l in
                WARN:*) warns+=${warns:+ $G_DOT }${l#WARN:} ;;
                NEXT:*) NEXT+=("${l#NEXT:}") ;;
            esac
        done <"$RUN/$id.status"
    fi
    if ((rc == 0)); then
        out=$(step check "$id" 2>>"$RUN/$id.log") || crc=$?
        if ((crc == 0)); then
            T_STATE[i]="done" T_DETAIL[i]=$out
            if [[ -n $warns ]]; then T_STATE[i]=warn T_DETAIL[i]=$warns; fi
            emit "$id" "${T_STATE[i]}" "${T_DETAIL[i]}"
            return 0
        fi
        reason="exited 0, but the check still says: $out"
    elif (($3)); then
        reason="timed out after $((T_TIMEOUT[i] / 60))m"
    else
        reason=$(fail_reason "$RUN/$id.log")
        reason=${reason:-exit $rc}
    fi
    T_DETAIL[i]=$reason T_STATE[i]=fail
    if [[ ${T_KIND[i]} == optional ]]; then T_STATE[i]=warn; fi
    emit "$id" "${T_STATE[i]}" "$reason" "rc=$rc"
    if [[ $UI_MODE == plain ]]; then explain "$i" 8; fi
}

stop_job() {  # SIGTERM the running step's whole process group, give it 3s, then SIGKILL and reap
    local _
    if [[ -n $TAIL_PID ]]; then kill "$TAIL_PID" 2>/dev/null || true; TAIL_PID=; fi
    if [[ -z $PID ]]; then return 0; fi
    kill -TERM -- "-$PID" 2>/dev/null || true
    for _ in {1..30}; do
        kill -0 -- "-$PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL -- "-$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=
}

exit_code() {
    local i
    for i in "${!T_ID[@]}"; do
        if ((CHECK_ONLY)) && [[ ${T_STATE[i]} == pending ]]; then echo 1; return 0; fi
        if [[ ${T_STATE[i]} == @(fail|blocked) && ${T_KIND[i]} == required ]]; then echo 1; return 0; fi
    done
    echo 0
}

on_exit() {
    local rc=$? cur_id=none
    set +e
    trap - ERR INT TERM HUP
    stop_job
    if ((CUR >= 0)); then cur_id=${T_ID[CUR]}; fi
    if ((INTERRUPTED && CUR >= 0)); then
        T_STATE[CUR]=fail T_DETAIL[CUR]=interrupted T_T1[CUR]=$SECONDS
        emit "${T_ID[CUR]}" interrupted
        if ((DRAWN)); then render 1; fi
    fi
    term_restore
    if ((INTERRUPTED)); then
        if [[ $UI_MODE == plain ]]; then
            printf 'servermaxxing result=interrupted step=%s log=%s\n' "$cur_id" "$RUN" | tee -a "$EVENTS"
        else
            printf '  %s%s interrupted%s' "$C_YEL" "$G_WARN" "$C_0"
            if ((CUR >= 0)); then printf ' during %s' "${T_LABEL[CUR]}"; fi
            printf ' %s steps already done are detected and skipped on the next run\n' "$G_DOT"
            if [[ $cur_id == @(repair|apt|node|docker|extras|agent) ]]; then
                printf '  %snext%s  re-run servermaxxing: if dpkg was mid-install it gets repaired first\n' "$C_CYN" "$C_0"
            fi
            printf '  %slog%s   %s\n' "$C_DIM" "$C_0" "$RUN"
        fi
    elif ((rc != 0 && !FINISHED)); then
        printf '\nservermaxxing: stopped unexpectedly (exit %s) at %s\n  log: %s\n' "$rc" "${ERR_INFO:-unknown}" "${RUN:-none}" >&2
    fi
}

# ── 5. helpers for step bodies (these run inside the step's background subshell) ──

say() { printf '%s\n' "$*" >>"$RUN/$CUR_ID.status"; printf '==> %s\n' "$*"; }
warn() { printf 'WARN:%s\n' "$*" >>"$RUN/$CUR_ID.status"; printf 'WARN: %s\n' "$*"; }
next_step() { printf 'NEXT:%s\n' "$*" >>"$RUN/$CUR_ID.status"; }

fetch() {  # fetch <url> <file>: fails loudly, never leaves a half-download looking like success
    say "downloading ${1#https://}"
    curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 -o "$2" "$1"
}

run_installer() {  # run_installer <url> <sh|bash> [VAR=value...]: download first, so a failed
    local url=$1 interp=$2 f  # download fails the step instead of running an empty script
    f=$RUN/$CUR_ID.${url##*/}
    shift 2
    fetch "$url" "$f"
    say "running ${url#https://}"
    env "$@" "$interp" "$f"
}

apt_get() {  # apt-get that waits for the dpkg lock and reports machine-readable progress on fd 3
    apt-get -y -q -o DPkg::Lock::Timeout=180 -o Dpkg::Use-Pty=0 -o APT::Status-Fd=3 "$@" 3>>"$RUN/$CUR_ID.progress"
}

apt_update() {  # the package-lists lock has no timeout option, so retry while something else holds it
    local n out=$RUN/$CUR_ID.update
    for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
        say "updating package index"
        if apt_get update 2>&1 | tee "$out"; then : >"$RUN/apt-updated"; return 0; fi
        if ! grep -q 'Could not get lock' "$out"; then return 1; fi
        say "package index locked by another apt process, retrying in 10s ($n/12)"
        sleep 10
    done
    return 1
}

apt_install() {  # apt_install <apt-get install args...>: refresh the index once per run, then install
    if [[ ! -e $RUN/apt-updated ]]; then apt_update; fi
    apt_get install "$@"
}

pkg_installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }
pkg_available() { [[ $(apt-cache policy "$1" 2>/dev/null) == *'Candidate: '[!\(]* ]]; }
apt_lists() { compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null; }
dpkg_interrupted() { compgen -G '/var/lib/dpkg/updates/*' >/dev/null; }

have_cmd() {  # have_cmd <bin> [version args...]: print its version (or "installed"); 1 if missing or broken
    local out
    if ! command -v "$1" >/dev/null 2>&1; then echo "not installed"; return 1; fi
    if (($# == 1)); then echo installed; return 0; fi
    if ! out=$(timeout 20 "$@" 2>&1); then echo "installed, but '$*' fails"; return 1; fi
    if [[ $out =~ v?[0-9]+\.[0-9]+(\.[0-9]+)? ]]; then out=${BASH_REMATCH[0]}; else out=installed; fi
    echo "$out"
}

unit_state() { local s; s=$(systemctl is-enabled "$1" 2>/dev/null) || true; echo "${s:-not-found}"; }

sleep_masked() {
    local t
    for t in "${SLEEP_TARGETS[@]}"; do [[ $(unit_state "$t") == masked ]] || return 1; done
}

no_systemd() {  # print why a systemd-only step does not apply here, if it does not
    if [[ $HOST_KIND == container ]]; then echo "container: not applicable"; return 0; fi
    if ((!HAS_SYSTEMD)); then echo "no systemd: not applicable"; return 0; fi
    return 1
}

# ── 6. host ────────────────────────────────────────────────────────────────────

resolve_target() {
    TARGET_USER=${SUDO_USER:-$(logname 2>/dev/null || id -un)}
    TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6) || TARGET_HOME=
    if [[ -z $TARGET_HOME ]]; then
        TARGET_HOME=/home/$TARGET_USER
        if [[ $TARGET_USER == root ]]; then TARGET_HOME=/root; fi
    fi
}

detect_host() {
    local chassis= vendor= model= dmi=/sys/class/dmi/id
    HAS_SYSTEMD=0
    if [[ -d /run/systemd/system ]]; then HAS_SYSTEMD=1; fi
    # systemd-detect-virt prints "none" *and* exits 1 on bare metal, so never append a fallback to its output.
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null) || true
    VIRT_TYPE=${VIRT_TYPE:-none}
    { read -r chassis <"$dmi/chassis_type"; } 2>/dev/null || true
    if [[ $VIRT_TYPE != none ]]; then
        HOST_KIND=vm
        if systemd-detect-virt --container >/dev/null 2>&1; then HOST_KIND=container; fi
        HOST_LABEL="$HOST_KIND ($VIRT_TYPE)"
    elif [[ -f /.dockerenv || -f /run/.containerenv ]]; then
        HOST_KIND=container HOST_LABEL=container
    else
        HOST_KIND=server
        if compgen -G "/sys/class/power_supply/BAT*" >/dev/null || [[ $chassis =~ ^(8|9|10|11|14|30|31|32)$ ]]; then
            HOST_KIND=laptop
        fi
        { read -r vendor <"$dmi/sys_vendor"; } 2>/dev/null || true
        if [[ $vendor == LENOVO ]]; then
            { read -r model <"$dmi/product_version"; } 2>/dev/null || true
        else
            { read -r model <"$dmi/product_name"; } 2>/dev/null || true
        fi
        if [[ $model == *@(O.E.M|System\ Product|Default\ string|To\ be\ filled)* ]]; then model=; fi
        HOST_LABEL=$HOST_KIND
        if [[ $HOST_KIND == server ]]; then HOST_LABEL="bare metal"; fi
        if [[ -n $model ]]; then HOST_LABEL+=" ($model)"; fi
    fi
    OS_NAME=$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" ) || OS_NAME=
    OS_NAME=${OS_NAME:-$(uname -sr)}
    CPUS=$(nproc 2>/dev/null) || CPUS="?"
    MEM=$(awk '$1 == "MemTotal:" { g = $2 / 1048576; printf (g < 10 ? "%.1f GB" : "%.0f GB"), g }' /proc/meminfo 2>/dev/null) || MEM=
}

# ── 7. steps ───────────────────────────────────────────────────────────────────
# check_<id>: local and side-effect free, so it can run before anything else. Prints a short detail
#   and returns 0 = already in place, 1 = needs work, 2 = not applicable here.
# run_<id>: runs in a background subshell with errexit on and all output going to the step's log.
#   It passes only if it exits 0 and check_<id> passes afterwards.

check_repair() { if dpkg_interrupted; then echo "dpkg was interrupted"; return 1; fi; echo "dpkg consistent"; }
run_repair() { say "dpkg --configure -a"; dpkg --configure -a; }

check_power() {
    local todo=() ok=() f v
    if no_systemd; then return 2; fi
    if [[ $HOST_KIND == vm ]]; then echo "vm: not applicable"; return 2; fi
    if sleep_masked; then ok+=("sleep masked"); else todo+=(sleep); fi
    if [[ $HOST_KIND == laptop ]]; then
        if grep -qs '^HandleLidSwitch=ignore' /etc/systemd/logind.conf.d/ignore-lid.conf; then ok+=("lid ignored"); else todo+=(lid); fi
        if [[ -d /etc/NetworkManager/conf.d ]]; then
            if grep -qs '^wifi.powersave = 2' /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf; then
                ok+=("wifi powersave off")
            else
                todo+=("wifi powersave")
            fi
        fi
        for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
            if [[ ! -e $f ]]; then continue; fi
            v=$(<"$f")
            if [[ $v == 80 ]]; then ok+=("battery cap 80%"); else todo+=("battery cap (now $v%)"); fi
        done
    fi
    if ((${#todo[@]})); then echo "to do: ${todo[*]}"; return 1; fi
    join_dot "${ok[@]}"
}

run_power() {
    local f
    say "masking sleep targets"
    systemctl mask "${SLEEP_TARGETS[@]}"
    if [[ $HOST_KIND != laptop ]]; then return 0; fi
    say "ignoring the lid switch"
    mkdir -p /etc/systemd/logind.conf.d
    cat >/etc/systemd/logind.conf.d/ignore-lid.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no
EOF
    systemctl kill -s HUP systemd-logind || true
    # Wi-Fi power saving adds latency and drops SSH/Tailscale sessions.
    if [[ -d /etc/NetworkManager/conf.d ]]; then
        say "turning off wifi power saving"
        printf '[connection]\nwifi.powersave = 2\n' >/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
        systemctl reload NetworkManager || true
    fi
    # Battery longevity: an 80% cap stops the cell sitting at 100% on AC around the clock.
    for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
        if [[ ! -e $f ]]; then continue; fi
        say "capping battery charge at 80%"
        echo 80 >"$f"
    done
}

check_debloat() {
    local u s todo=()
    if no_systemd; then return 2; fi
    for u in ModemManager multipathd; do
        s=$(unit_state "$u.service")
        if [[ $s != @(masked|not-found) ]]; then todo+=("$u"); fi
    done
    s=$(unit_state fwupd.service)
    if [[ $s != @(disabled|masked|static|indirect|not-found) ]]; then todo+=(fwupd); fi
    if ((${#todo[@]})); then echo "to disable: ${todo[*]}"; return 1; fi
    join_dot ModemManager multipathd "fwupd off"
}

run_debloat() {
    local u
    for u in ModemManager multipathd; do
        say "masking $u"
        systemctl stop "$u.service" 2>/dev/null || true
        systemctl mask "$u.service"
    done
    say "disabling fwupd"
    systemctl stop fwupd.service 2>/dev/null || true
    systemctl disable fwupd.service 2>/dev/null || true
}

check_snaps() {
    local s todo=()
    if ! command -v snap >/dev/null; then echo "snapd not installed"; return 2; fi
    for s in hwctl lxd; do
        if snap list "$s" >/dev/null 2>&1; then todo+=("$s"); fi
    done
    if ((${#todo[@]})); then echo "to remove: ${todo[*]}"; return 1; fi
    echo "no hwctl or lxd"
}

run_snaps() {
    local s
    for s in hwctl lxd; do
        if snap list "$s" >/dev/null 2>&1; then say "removing $s"; snap remove "$s"; fi
    done
}

check_apt() {
    local p n=0 missing=() unavailable=()
    for p in "${CLI_PACKAGES[@]}"; do
        if pkg_installed "$p"; then
            n=$((n + 1))
        elif apt_lists && ! pkg_available "$p"; then
            unavailable+=("$p")
        else
            missing+=("$p")
        fi
    done
    if ((${#missing[@]})); then echo "to install: ${missing[*]}"; return 1; fi
    if ! command -v fd >/dev/null && command -v fdfind >/dev/null; then echo "to do: fd symlink"; return 1; fi
    if ((${#unavailable[@]})); then join_dot "$n packages" "${unavailable[*]} not in this release"; else echo "$n packages"; fi
}

run_apt() {
    local p want=()
    apt_update
    for p in "${CLI_PACKAGES[@]}"; do
        if pkg_installed "$p"; then continue; fi
        # Install what this release has instead of letting one missing package (fastfetch is not in
        # Ubuntu 22.04/24.04) fail the whole transaction.
        if pkg_available "$p"; then want+=("$p"); else warn "$p is not in this release's archive"; fi
    done
    if ((${#want[@]})); then
        say "installing ${want[*]}"
        apt_install --no-install-recommends "${want[@]}"
    fi
    if ! command -v fd >/dev/null && command -v fdfind >/dev/null; then ln -sf "$(command -v fdfind)" /usr/local/bin/fd; fi
}

check_zram() {
    local cfg=/etc/default/zramswap size
    if no_systemd; then return 2; fi
    if ! grep -qs '^ALGO=zstd' "$cfg" || ! grep -qs '^PERCENT=50' "$cfg"; then echo "to do: zstd, 50% of RAM"; return 1; fi
    size=$(awk '$1 ~ /zram/ { printf "%.1f GB", $3 / 1048576; exit }' /proc/swaps 2>/dev/null) || size=
    if [[ -z $size ]]; then echo "to do: start zramswap"; return 1; fi
    join_dot zstd "50% RAM" "$size active"
}

run_zram() {
    say "configuring zstd, 50% of RAM"
    printf 'ALGO=zstd\nPERCENT=50\nPRIORITY=100\n' >/etc/default/zramswap
    say "restarting zramswap"
    systemctl restart zramswap.service
}

check_uv() { have_cmd uv --version; }
run_uv() { run_installer https://astral.sh/uv/install.sh sh UV_INSTALL_DIR=/usr/local/bin; }

check_node() { have_cmd node --version; }
run_node() { say "installing nodejs npm"; apt_install nodejs npm; }

check_vp() { have_cmd vp --version; }
run_vp() {
    local f bin
    f=$(mktemp /tmp/servermaxxing-vp.XXXXXX)   # world-readable copy: the installer runs as the target user
    fetch https://vite.plus "$f"
    chmod 644 "$f"
    say "installing Vite+ for $TARGET_USER"
    su - "$TARGET_USER" -c "VP_NODE_MANAGER=yes bash $f" </dev/null
    rm -f "$f"
    bin=$(find "$TARGET_HOME/.vite-plus" "$TARGET_HOME/.local/share/vite-plus" -name vp -type f 2>/dev/null | head -n 1) || true
    if [[ -z $bin || ! -x $bin ]]; then echo "vp binary not found under $TARGET_HOME after install"; return 1; fi
    ln -sf "$bin" /usr/local/bin/vp
}

check_agent() {
    case $AGENT_CHOICE in
        claude|codex) have_cmd "$AGENT_CHOICE" --version ;;
        *) have_cmd "$AGENT_CHOICE" ;;
    esac
}

run_agent() {
    case $AGENT_CHOICE in
        claude) say "npm install -g @anthropic-ai/claude-code"; npm install -g --no-fund --no-audit @anthropic-ai/claude-code ;;
        codex) say "npm install -g @openai/codex"; npm install -g --no-fund --no-audit @openai/codex ;;
        *) "install_$AGENT_CHOICE" ;;
    esac
}

check_docker() {
    local v
    if ! v=$(have_cmd docker --version); then echo "$v"; return 1; fi
    if [[ $TARGET_USER != root && " $(id -nG "$TARGET_USER" 2>/dev/null) " != *" docker "* ]]; then
        echo "to do: add $TARGET_USER to the docker group"; return 1
    fi
    if ((HAS_SYSTEMD)) && [[ $(systemctl is-active docker 2>/dev/null) != active ]]; then echo "to do: start docker"; return 1; fi
    echo "$v"
}

run_docker() {
    if ! command -v docker >/dev/null; then
        say "installing docker.io docker-compose-v2 docker-buildx"
        if ! apt_install docker.io docker-compose-v2 docker-buildx; then
            say "no docker packages in apt here, using get.docker.com"
            run_installer https://get.docker.com sh
        fi
    fi
    if ((HAS_SYSTEMD)); then say "enabling docker"; systemctl enable --now docker; fi
    if [[ $TARGET_USER != root ]] && [[ " $(id -nG "$TARGET_USER") " != *" docker "* ]]; then
        say "adding $TARGET_USER to the docker group"
        usermod -aG docker "$TARGET_USER"
        next_step "log out and back in so $TARGET_USER can use docker without sudo"
    fi
}

check_tailscale() {
    local v
    if ! v=$(have_cmd tailscale --version); then echo "$v"; return 1; fi
    if ((HAS_SYSTEMD)) && [[ $(systemctl is-active tailscaled 2>/dev/null) != active ]]; then echo "to do: start tailscaled"; return 1; fi
    if tailscale status >/dev/null 2>&1; then join_dot "$v" connected; return 0; fi
    if [[ -n ${TAILSCALE_AUTHKEY:-} ]]; then echo "to do: join the tailnet with TAILSCALE_AUTHKEY"; return 1; fi
    join_dot "$v" "not logged in"
}

run_tailscale() {
    if ! command -v tailscale >/dev/null; then run_installer https://tailscale.com/install.sh sh; fi
    if ((HAS_SYSTEMD)); then say "enabling tailscaled"; systemctl enable --now tailscaled; fi
    if [[ -n ${TAILSCALE_AUTHKEY:-} ]]; then
        say "joining the tailnet with TAILSCALE_AUTHKEY"
        tailscale up --authkey="$TAILSCALE_AUTHKEY"
    fi
}

extra_bin() { if [[ $1 == superfile ]]; then echo spf; else echo "$1"; fi; }

check_extras() {
    local t todo=()
    for t in "${EXTRAS[@]}"; do
        if ! command -v "$(extra_bin "$t")" >/dev/null; then todo+=("$t"); fi
    done
    if ((${#todo[@]})); then echo "to install: ${todo[*]}"; return 1; fi
    join_dot "${EXTRAS[@]}"
}

run_extras() {
    local t n=0 failed=()
    for t in "${EXTRAS[@]}"; do
        n=$((n + 1))
        if command -v "$(extra_bin "$t")" >/dev/null; then continue; fi
        say "installing $t ($n/${#EXTRAS[@]})"
        # A plain background job keeps errexit live inside the installer; `if install_$t` would not.
        "install_$t" &
        if ! wait $!; then failed+=("$t"); warn "$t failed to install"; fi
    done
    if ((${#failed[@]})); then return 1; fi
}

install_superfile() { run_installer https://superfile.dev/install.sh bash; }
install_herdr() { run_installer https://herdr.dev/install.sh sh HERDR_INSTALL_DIR=/usr/local/bin; }
install_tuios() { run_installer https://raw.githubusercontent.com/Gaurav-Gosain/tuios/main/install.sh bash; }
install_speedtest() {
    run_installer https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh bash
    say "installing speedtest"
    apt_get install speedtest
}
install_neofetch() {
    fetch https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch /usr/local/bin/neofetch
    chmod +x /usr/local/bin/neofetch
}

sudoers_file() { echo "/etc/sudoers.d/${TARGET_USER//./_}"; }   # sudo skips files whose names contain a dot

check_sudoers() {
    local out=
    if [[ $TARGET_USER == root ]]; then echo "root: not needed"; return 2; fi
    if ! command -v sudo >/dev/null; then echo "sudo not installed"; return 2; fi
    if ((EUID == 0)); then
        out=$(sudo -l -U "$TARGET_USER" 2>/dev/null) || out=
    elif [[ $(id -un) == "$TARGET_USER" ]] && sudo -n true 2>/dev/null; then
        out="NOPASSWD: ALL"
    fi
    if [[ $out == *"NOPASSWD: ALL"* ]]; then echo "passwordless for $TARGET_USER"; return 0; fi
    echo "to do: passwordless sudo for $TARGET_USER"
    return 1
}

run_sudoers() {
    local f tmp
    f=$(sudoers_file)
    tmp=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" >"$tmp"
    say "validating with visudo"
    visudo -cf "$tmp"
    install -m 0440 -o root -g root "$tmp" "$f"
    rm -f "$tmp"
}

# ── 8. demo: simulated steps for previewing the UI (no root, no changes) ───────

demo_check() {
    case $1 in
        power|uv|docker) demo_detail "$1"; return 0 ;;
        snaps) echo "snapd not installed"; return 2 ;;
    esac
    if [[ -e $RUN/$1.demo ]]; then demo_detail "$1"; return 0; fi
    case $1 in
        apt) echo "to install: ripgrep fd-find fzf btop zram-tools +5" ;;
        extras) echo "to install: ${EXTRAS[*]}" ;;
        *) echo "to do" ;;
    esac
    return 1
}

demo_detail() {
    case $1 in
        power) join_dot "sleep masked" "lid ignored" "wifi powersave off" "battery cap 80%" ;;
        debloat) join_dot ModemManager multipathd "fwupd off" ;;
        apt) join_dot "10 packages" "fastfetch not in this release" ;;
        zram) join_dot zstd "50% RAM" "7.8 GB active" ;;
        uv) echo 0.9.2 ;;
        node) echo v20.18.1 ;;
        vp) echo 0.1.4 ;;
        agent) echo 2.0.14 ;;
        docker) echo 28.2.2 ;;
        tailscale) join_dot 1.88.3 "not logged in" ;;
        extras) join_dot "${EXTRAS[@]}" ;;
        sudoers) echo "passwordless for $TARGET_USER" ;;
    esac
}

demo_run() {
    local id=$1 i p pct=0 t
    case $id in
        apt)
            say "updating package index"
            for i in 1 2 3 4 5 6; do echo "Get:$i http://archive.ubuntu.com/ubuntu noble/universe amd64 Packages [15.0 MB]"; sleep 0.3; done
            warn "fastfetch is not in this release's archive"
            say "installing 10 packages"
            for p in ripgrep fd-find fzf ncdu tree tmux jq btop htop zram-tools; do
                pct=$((pct + 10))
                echo "Unpacking $p (1.0-1) ..."
                printf 'pmstatus:%s:%d.0:Unpacking %s (amd64)\n' "$p" $((pct - 5)) "$p" >>"$RUN/$CUR_ID.progress"
                sleep 0.3
                echo "Setting up $p (1.0-1) ..."
                printf 'pmstatus:%s:%d.0:Installed %s (amd64)\n' "$p" "$pct" "$p" >>"$RUN/$CUR_ID.progress"
                sleep 0.2
            done ;;
        extras)
            for t in "${EXTRAS[@]}"; do
                say "installing $t"
                sleep 0.6
                if [[ $t == tuios ]]; then
                    echo "curl: (22) The requested URL returned error: 403"
                    echo "API rate limit exceeded for 203.0.113.7"
                    warn "tuios failed to install"
                fi
            done
            return 1 ;;
        *)
            say "working"
            for i in 1 2 3; do echo "demo: $id, part $i of 3"; sleep 0.4; done ;;
    esac
    : >"$RUN/$id.demo"
}

# ── 9. handoff ─────────────────────────────────────────────────────────────────

seed_skill() {  # copy the servermaxxing skill into the target user's ~/.agents (explicit returns: called from ||)
    local dir=$TARGET_HOME/.agents/skills/servermaxxing src= here
    mkdir -p "$dir" || return 1
    if [[ -f ${BASH_SOURCE[0]:-} ]]; then
        here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || here=
        for src in "$here/../.agents/skills/servermaxxing/SKILL.md" "$here/.agents/skills/servermaxxing/SKILL.md" ""; do
            if [[ -n $src && -f $src ]]; then break; fi
        done
    fi
    if [[ -n $src ]]; then
        cp -f "$src" "$dir/SKILL.md" || return 1
    else
        curl -fsSL --connect-timeout 10 --max-time 60 "$REPO_RAW/.agents/skills/servermaxxing/SKILL.md" -o "$dir/SKILL.md" || return 1
    fi
    chown -R "$TARGET_USER:" "$TARGET_HOME/.agents" || return 1
}

decide_launch() {
    local i why=
    if [[ -z $AGENT_CHOICE ]] || ((CHECK_ONLY || DEMO)); then return 0; fi
    if [[ $UI_MODE != live || $TTY_OK != 1 ]]; then why="no interactive terminal"; fi
    if [[ -n $HEADLESS ]]; then why="running under ${HEADLESS}"; fi
    if ((NO_LAUNCH)); then why="--no-launch"; fi
    for i in "${!T_ID[@]}"; do
        if [[ ${T_STATE[i]} == @(fail|blocked) && ${T_KIND[i]} == required ]]; then why="a required step failed"; fi
    done
    if [[ -z $why ]]; then LAUNCH=1; return 0; fi
    NEXT+=("start $AGENT_CHOICE: su - $TARGET_USER -c '$AGENT_CHOICE'   (not launched: $why)")
}

countdown() {  # 0 = launch now, 1 = stay in the shell
    local s
    trap 'LAUNCH_ABORT=1' INT
    for s in 3 2 1; do
        printf '\r\e[2K  %s%s%s launching %s as %s in %ss   %senter: now %s ctrl-c: stay in this shell%s' \
            "$C_CYN" "$G_TICK" "$C_0" "$AGENT_CHOICE" "$TARGET_USER" "$s" "$C_DIM" "$G_DOT" "$C_0"
        if read -rsn1 -t 1 _ </dev/tty; then break; fi
        if ((LAUNCH_ABORT)); then break; fi
    done
    trap 'INTERRUPTED=1; exit 130' INT
    printf '\n'
    if ((LAUNCH_ABORT)); then
        printf '  start it later with: su - %s -c %s\n' "$TARGET_USER" "'$AGENT_CHOICE'"
        return 1
    fi
}

launch() {
    local cmd=$AGENT_CHOICE
    if [[ $AGENT_CHOICE == @(claude|codex) ]]; then cmd="cd ~ && $AGENT_CHOICE \"$AUDIT_PROMPT\""; fi
    exec </dev/tty >/dev/tty 2>&1   # under `curl | bash` stdin is still the pipe, not the terminal
    exec su - "$TARGET_USER" -c "$cmd"
}

# ── main ───────────────────────────────────────────────────────────────────────

setup_run_dir() {
    local base=/var/log/servermaxxing ts
    if ((EUID == 0 && !DEMO)); then
        # Not /tmp: a root script writing a predictable path in a world-writable dir invites symlink attacks.
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        RUN=$base/$ts
        (umask 077 && mkdir -p "$RUN")
        ln -sfn "$ts" "$base/latest"
    else
        RUN=$(mktemp -d "${TMPDIR:-/tmp}/servermaxxing.XXXXXX")
    fi
    EVENTS=$RUN/events.log
    : >"$EVENTS"
}

main() {
    local code parts
    parse_args "$@"
    T_START=$SECONDS
    resolve_target
    detect_host
    register_tasks
    detect_context
    setup_style
    if ((!DEMO)); then
        command -v apt-get >/dev/null || die "servermaxxing supports Debian and Ubuntu (apt) only"
        ((EUID == 0 || CHECK_ONLY)) || die "needs root: run it with sudo (or try --check or --demo)"
    fi
    setup_run_dir
    trap on_exit EXIT
    trap 'INTERRUPTED=1; exit 130' INT
    trap 'INTERRUPTED=1; exit 143' TERM HUP
    trap 'ERR_INFO="line $LINENO: $BASH_COMMAND"' ERR
    if [[ $UI_MODE == live ]]; then trap 'RESIZED=1' WINCH; fi

    parts=("$HOST_LABEL" "$OS_NAME" "$CPUS cpu")
    if [[ -n $MEM ]]; then parts+=("$MEM"); fi
    parts+=("user $TARGET_USER")
    if [[ -n $AGENT_CHOICE ]]; then parts+=("agent $AGENT_CHOICE"); fi
    if ((CHECK_ONLY)); then parts+=("check only"); fi
    if ((DEMO)); then parts+=("demo"); fi
    HEADER=" $G_DOT $(join_dot "${parts[@]}")"
    printf 'servermaxxing start host=%s os=%s user=%s agent=%s ui=%s context=%s log=%s\n' "$HOST_KIND" "$(q "$OS_NAME")" \
        "$TARGET_USER" "${AGENT_CHOICE:-none}" "$UI_MODE" "${HEADLESS:-interactive}" "$RUN" >>"$EVENTS"
    if [[ $UI_MODE == plain ]]; then tail -n 1 "$EVENTS"; fi

    term_setup
    preflight
    if ((!CHECK_ONLY)); then run_all; fi
    if [[ -n $AGENT_CHOICE ]] && ((!CHECK_ONLY && !DEMO)); then
        seed_skill >>"$RUN/skill.log" 2>&1 || NEXT+=("the servermaxxing skill was not copied to ~/.agents, see $RUN/skill.log")
    fi
    decide_launch
    render 1
    term_restore
    summary
    FINISHED=1
    code=$(exit_code)
    if ((LAUNCH)) && countdown; then launch; fi
    exit "$code"
}

main "$@"
