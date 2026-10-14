#!/usr/bin/env bash
#
# deploy_agent.sh - Deploy, run, and archive the Student Attendance Tracker.
#
# Usage:
#   ./deploy_agent.sh                  interactive menu
#   ./deploy_agent.sh deploy           Feature 1: deploy a new project (then runs it)
#   ./deploy_agent.sh run [name]       Feature 2: run an already deployed project
#   ./deploy_agent.sh archive [name]   Feature 3: archive the project's logs
#   ./deploy_agent.sh help             show this help
#
# [name] is the suffix you chose at deploy time ("v1" -> attendance_tracker_v1).
# Written for bash 3.2+ so it runs on the macOS system bash as well as Linux.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
PREFIX="attendance_tracker_"
MAX_GENERATED=100

# State used by the interrupt handler.
PROJECT_DIR=""      # e.g. attendance_tracker_v1 - set only once WE create it
DEPLOY_ACTIVE=0     # 1 while Feature 1 is creating/setting up the project

# Return values for the input helpers (no command substitution, so the
# prompts run in the main shell where the signal traps live).
INT_VALUE=""
NAME_VALUE=""

# Sample data for Option B (fresh roster). 10 x 10 = 100 unique names.
FIRST_NAMES=(Alice Brian Chloe David Esther Felix Grace Henry Ines Jamal)
LAST_NAMES=(Mugisha Uwase Habimana Johnson Smith Okafor Mensah Garcia Kim Patel)

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
section() { printf '\n=== %s ===\n' "$*"; }
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  [OK] %s\n' "$*"; }
warn()    { printf '  [WARN] %s\n' "$*" >&2; }
die()     { printf '  [ERROR] %s\n' "$*" >&2; exit 1; }

# Fail during deployment: remove the half-made project so nothing is left behind.
deploy_fail() {
    printf '  [ERROR] %s\n' "$*" >&2
    if [ "$DEPLOY_ACTIVE" -eq 1 ] && [ -n "$PROJECT_DIR" ] && [ -d "$SCRIPT_DIR/$PROJECT_DIR" ]; then
        rm -rf "${SCRIPT_DIR:?}/$PROJECT_DIR" && info "Removed incomplete directory $PROJECT_DIR/."
    fi
    exit 1
}

usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; }

# --------------------------------------------------------------------------
# Signal handling (active only while Feature 1 is deploying)
# --------------------------------------------------------------------------
on_interrupt() {
    local sig="$1" code="$2"
    trap '' INT TSTP    # ignore repeated presses while we clean up

    printf '\n\n  !!! Deployment interrupted (%s). Cleaning up...\n' "$sig"

    if [ "$DEPLOY_ACTIVE" -eq 1 ] && [ -n "$PROJECT_DIR" ] && [ -d "$SCRIPT_DIR/$PROJECT_DIR" ]; then
        local zip_name="${PROJECT_DIR}_archive.zip"
        if ( cd "$SCRIPT_DIR" && rm -f "$zip_name" && zip -rq "$zip_name" "$PROJECT_DIR" ); then
            ok "Incomplete project archived to $zip_name"
            rm -rf "${SCRIPT_DIR:?}/$PROJECT_DIR" && ok "Removed incomplete directory $PROJECT_DIR/"
        else
            warn "zip failed - leaving $PROJECT_DIR/ in place so nothing is lost."
        fi
    else
        info "No project directory had been created yet - nothing to archive."
    fi

    info "Session closed."
    exit "$code"
}

enable_deploy_traps() {
    trap 'on_interrupt SIGINT 130' INT
    trap 'on_interrupt SIGTSTP 148' TSTP
}

disable_deploy_traps() {
    trap - INT TSTP
}

# --------------------------------------------------------------------------
# Input helpers
# --------------------------------------------------------------------------
trim() { # trims the variable named $1 in place
    local v="${!1}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    eval "$1=\$v"
}

# ask_yes_no "question" y|n  -> exit status 0 for yes, 1 for no
ask_yes_no() {
    local reply hint="y/N"
    [ "$2" = "y" ] && hint="Y/n"
    while true; do
        read -r -p "  $1 [$hint]: " reply || die "No input received."
        trim reply
        reply="${reply:-$2}"
        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

# read_int "prompt" default min max -> INT_VALUE (default may be "")
read_int() {
    local prompt="$1" default="$2" min="$3" max="$4" reply
    while true; do
        if [ -n "$default" ]; then
            read -r -p "  $prompt [$default]: " reply || die "No input received."
        else
            read -r -p "  $prompt: " reply || die "No input received."
        fi
        trim reply
        reply="${reply:-$default}"
        if [ -z "$reply" ]; then
            warn "Input cannot be empty."; continue
        fi
        case "$reply" in
            *[!0-9]*) warn "'$reply' is not a whole number."; continue ;;
        esac
        if [ "${#reply}" -gt 6 ]; then
            warn "'$reply' is too large."; continue
        fi
        reply=$((10#$reply))   # normalise leading zeros ("075" -> 75)
        if [ "$reply" -lt "$min" ] || [ "$reply" -gt "$max" ]; then
            warn "Enter a number between $min and $max."; continue
        fi
        INT_VALUE="$reply"
        return 0
    done
}

# read_project_name "prompt" -> NAME_VALUE (suffix only, validated)
read_project_name() {
    local reply
    while true; do
        read -r -p "  $1: " reply || die "No input received."
        trim reply
        reply="${reply#"$PREFIX"}"   # accept "v1" or "attendance_tracker_v1"
        reply="${reply%/}"
        if [ -z "$reply" ]; then
            warn "Name cannot be empty."; continue
        fi
        case "$reply" in
            *[!A-Za-z0-9_-]*) warn "Use only letters, digits, '_' or '-'."; continue ;;
        esac
        NAME_VALUE="$reply"
        return 0
    done
}

# --------------------------------------------------------------------------
# config.json editing (sed, in place, formatting preserved)
# --------------------------------------------------------------------------
# set_json_number file key value
#   Replaces only the number after "key": - nothing else in the file moves.
#   -i.bak + rm keeps it portable between GNU sed (Linux) and BSD sed (macOS).
set_json_number() {
    local file="$1" key="$2" value="$3"
    if ! grep -Eq "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$file"; then
        warn "\"$key\" not found in $(basename "$file")."
        return 1
    fi
    sed -E -i.bak "s/(\"$key\"[[:space:]]*:[[:space:]]*)[0-9]+/\1$value/" "$file" \
        && rm -f "$file.bak"
}

# --------------------------------------------------------------------------
# Shared checks
# --------------------------------------------------------------------------
preflight() {
    section "Pre-flight checks"
    local missing=0

    if command -v python3 >/dev/null 2>&1; then
        ok "python3 found: $(python3 --version 2>&1)"
    else
        warn "python3 is not installed (needed to run attendance_checker.py)."
        missing=1
    fi

    if command -v zip >/dev/null 2>&1; then
        ok "zip found: $(command -v zip)"
    else
        warn "zip is not installed (needed to archive interrupted deployments)."
        missing=1
    fi

    local f
    for f in attendance_checker.py assets.csv config.json; do
        if [ -r "$TEMPLATE_DIR/$f" ]; then
            ok "template found: templates/$f"
        else
            warn "templates/$f is missing or unreadable."
            missing=1
        fi
    done

    if [ ! -w "$SCRIPT_DIR" ]; then
        warn "No write permission in $SCRIPT_DIR - cannot create the project here."
        missing=1
    fi

    [ "$missing" -eq 0 ] || die "Pre-flight checks failed. Fix the issues above and re-run."
}

# Ask for (or take from $1) the name of an existing project -> PROJECT_PATH
choose_existing_project() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        local found=0 d
        for d in "$SCRIPT_DIR"/${PREFIX}*/; do
            [ -d "$d" ] || continue
            [ "$found" -eq 0 ] && info "Deployed projects:"
            found=1
            d="${d%/}"
            info "  - ${d##*/}"
        done
        [ "$found" -eq 1 ] || die "No deployed projects found. Run the deploy feature first."
        read_project_name "Project name (e.g. v1)"
        name="$NAME_VALUE"
    fi
    name="${name#"$PREFIX"}"
    name="${name%/}"
    PROJECT_PATH="$SCRIPT_DIR/${PREFIX}${name}"
    [ -d "$PROJECT_PATH" ] || die "Project ${PREFIX}${name}/ does not exist."
}

# --------------------------------------------------------------------------
# Feature 1: Deploy
# --------------------------------------------------------------------------
build_roster_from_template() { # dest
    local dest="$1" available
    available=$(awk 'NR > 1 && NF' "$TEMPLATE_DIR/assets.csv" | wc -l | tr -d ' ')
    [ "$available" -gt 0 ] || deploy_fail "templates/assets.csv has no student rows."

    read_int "How many students to copy (1-$available)" "$available" 1 "$available"
    awk -v n="$INT_VALUE" 'NR == 1 { print; next } NF && c < n { print; c++ }' \
        "$TEMPLATE_DIR/assets.csv" > "$dest" \
        || deploy_fail "Could not write $dest (permission denied?)."
    ok "Copied header + $INT_VALUE student(s) from templates/assets.csv"
}

build_fresh_roster() { # dest
    local dest="$1" i first last email
    read_int "How many students to generate (1-$MAX_GENERATED)" "" 1 "$MAX_GENERATED"

    {
        echo "Email,Names,Attendance Count,Absence Count"
        i=0
        while [ "$i" -lt "$INT_VALUE" ]; do
            # Offset the surname by the "round" so all 100 combinations are unique.
            first="${FIRST_NAMES[$((i % 10))]}"
            last="${LAST_NAMES[$(((i / 10 + i) % 10))]}"
            email="$(printf '%s.%s@example.com' "$first" "$last" | tr '[:upper:]' '[:lower:]')"
            echo "$email,$first $last,0,0"
            i=$((i + 1))
        done
    } > "$dest" || deploy_fail "Could not write $dest (permission denied?)."
    ok "Generated $INT_VALUE student(s) with Attendance/Absence counts at 0"
}

update_thresholds() { # config_file
    local config="$1" warning failure
    section "Attendance alert thresholds"
    info "Current values:"
    grep -E '"(warning|failure)"' "$config" | sed 's/^/    /'

    if ! ask_yes_no "Update the alert thresholds?" n; then
        info "Keeping the default thresholds."
        return 0
    fi

    while true; do
        read_int "Warning threshold %" 75 0 100; warning="$INT_VALUE"
        read_int "Failure threshold %" 50 0 100; failure="$INT_VALUE"
        if [ "$failure" -lt "$warning" ]; then
            break
        fi
        warn "Failure threshold ($failure) must be lower than warning threshold ($warning). Try again."
    done

    set_json_number "$config" warning "$warning" || deploy_fail "Could not update warning threshold."
    set_json_number "$config" failure "$failure" || deploy_fail "Could not update failure threshold."
    chmod 600 "$config"   # keep owner-only after the in-place edit
    ok "Thresholds updated with sed:"
    grep -E '"(warning|failure)"' "$config" | sed 's/^/    /'
}

deploy() {
    enable_deploy_traps
    DEPLOY_ACTIVE=1
    PROJECT_DIR=""

    preflight

    # --- Name the project --------------------------------------------------
    section "Project name"
    read_project_name "Enter a name for the project (creates ${PREFIX}<name>/)"
    local name="$NAME_VALUE"
    local dir_name="${PREFIX}${name}"
    local dir="$SCRIPT_DIR/$dir_name"

    if [ -e "$dir" ]; then
        warn "$dir_name/ already exists."
        if ask_yes_no "Overwrite it? This deletes the existing project" n; then
            rm -rf "$dir" || die "Could not remove $dir_name/ (permission denied?)."
            ok "Removed the old $dir_name/"
        else
            die "Aborted: $dir_name/ already exists and was left untouched."
        fi
    fi

    # From here on the directory is ours: the trap may archive and remove it.
    PROJECT_DIR="$dir_name"

    # --- Create the structure ---------------------------------------------
    section "Creating directory structure"
    mkdir -p "$dir/Helpers" "$dir/reports" \
        || deploy_fail "Could not create $dir_name/ (permission denied?)."
    ok "$dir_name/"
    ok "$dir_name/Helpers/"
    ok "$dir_name/reports/"

    # --- Populate files ----------------------------------------------------
    section "Deploying files"
    cp "$TEMPLATE_DIR/attendance_checker.py" "$dir/attendance_checker.py" \
        || deploy_fail "Could not copy attendance_checker.py."
    ok "attendance_checker.py (from templates/)"
    cp "$TEMPLATE_DIR/config.json" "$dir/Helpers/config.json" \
        || deploy_fail "Could not copy config.json."
    ok "Helpers/config.json (from templates/)"

    section "Building the roster (Helpers/assets.csv)"
    info "A) Copy students from templates/assets.csv (each has 4 prior sessions)"
    info "B) Generate a fresh roster (counts start at 0)"
    local choice
    while true; do
        read -r -p "  Choose A or B: " choice || die "No input received."
        trim choice
        case "$choice" in
            [Aa]) build_roster_from_template "$dir/Helpers/assets.csv"; break ;;
            [Bb]) build_fresh_roster "$dir/Helpers/assets.csv"
                  # A fresh roster means today is session one.
                  set_json_number "$dir/Helpers/config.json" total_sessions 1 \
                      || deploy_fail "Could not set total_sessions."
                  ok "Set total_sessions to 1 in Helpers/config.json (fresh roster)"
                  break ;;
            *) warn "Please enter A or B." ;;
        esac
    done

    # --- Permissions -------------------------------------------------------
    section "Setting permissions"
    chmod +x "$dir/attendance_checker.py" || deploy_fail "chmod +x failed."
    chmod 600 "$dir/Helpers/config.json"  || deploy_fail "chmod 600 failed."
    ok "attendance_checker.py  -> $(ls -l "$dir/attendance_checker.py" | awk '{print $1}')  (executable)"
    ok "Helpers/config.json    -> $(ls -l "$dir/Helpers/config.json" | awk '{print $1}')  (owner read/write only)"

    # --- Thresholds --------------------------------------------------------
    update_thresholds "$dir/Helpers/config.json"

    # --- Done: disarm the trap before handing over to the app --------------
    DEPLOY_ACTIVE=0
    disable_deploy_traps

    section "Deployment complete"
    ok "Project ready at $dir_name/"
    info "Verifying the deployment by starting the application..."
    run_app "$name"
}

# --------------------------------------------------------------------------
# Feature 2: Run
# --------------------------------------------------------------------------
run_app() {
    command -v python3 >/dev/null 2>&1 || die "python3 is not installed."
    choose_existing_project "${1:-}"
    local dir="$PROJECT_PATH" f
    local dir_name="${dir##*/}"

    section "Running $dir_name"
    for f in attendance_checker.py Helpers/assets.csv Helpers/config.json; do
        [ -f "$dir/$f" ] || die "$dir_name/$f is missing - the project is not fully deployed."
    done
    [ -d "$dir/reports" ] || die "$dir_name/reports/ is missing - the project is not fully deployed."
    ok "Structure verified. Handing the terminal to the instructor..."
    echo

    # A no-op INT trap: Ctrl+C ends the marking session (the child gets the
    # default handler) but this script survives to offer archiving.
    trap ':' INT
    ( cd "$dir" && python3 attendance_checker.py )
    local status=$?
    trap - INT

    echo
    if [ "$status" -eq 0 ]; then
        ok "attendance_checker.py finished successfully."
    else
        warn "attendance_checker.py exited with status $status."
    fi

    if [ -f "$dir/reports/attendance.log" ] || [ -f "$dir/reports/absent.log" ]; then
        if ask_yes_no "Archive the generated logs now?" y; then
            archive_logs "${dir_name#"$PREFIX"}"
        fi
    fi
}

# --------------------------------------------------------------------------
# Feature 3: Archive logs
# --------------------------------------------------------------------------
archive_logs() {
    choose_existing_project "${1:-}"
    local dir="$PROJECT_PATH"
    local dir_name="${dir##*/}"
    local ts log src dest archived=0
    ts="$(date +%Y%m%d_%H%M%S)"

    section "Archiving logs for $dir_name"
    for log in attendance absent; do
        src="$dir/reports/$log.log"
        if [ ! -f "$src" ]; then
            info "[SKIP] reports/$log.log not found - nothing to archive."
            continue
        fi
        mkdir -p "$dir/archives/$log" || die "Could not create archives/$log/ (permission denied?)."
        dest="$dir/archives/$log/${log}_${ts}.log"
        mv "$src" "$dest" || die "Could not move reports/$log.log (permission denied?)."
        ok "reports/$log.log -> $dir_name/archives/$log/${log}_${ts}.log"
        archived=$((archived + 1))
    done

    if [ "$archived" -eq 0 ]; then
        info "No logs found. Run the application first to generate them."
    else
        ok "$archived log(s) archived."
    fi
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
menu() {
    local choice
    while true; do
        section "Attendance Tracker Deploy Agent"
        info "1) Deploy a new project"
        info "2) Run a deployed project"
        info "3) Archive a project's logs"
        info "4) Exit"
        read -r -p "  Select an option [1-4]: " choice || exit 0
        trim choice
        case "$choice" in
            1) deploy ;;
            2) run_app ;;
            3) archive_logs ;;
            4|q|Q) info "Goodbye."; exit 0 ;;
            *) warn "Invalid option '$choice'." ;;
        esac
    done
}

cd "$SCRIPT_DIR" || die "Cannot enter $SCRIPT_DIR."

case "${1:-}" in
    "")                  menu ;;
    deploy|-d|--deploy)  deploy ;;
    run|-r|--run)        run_app "${2:-}" ;;
    archive|-a|--archive) archive_logs "${2:-}" ;;
    help|-h|--help)      usage ;;
    *) warn "Unknown option '$1'."; usage; exit 1 ;;
esac
