#!/bin/bash
# knox-ask v2 — intelligent prompt runner with safe auto-decomposition
# Replaces /usr/local/bin/knox-ask

TIMEOUT=45
MAX_DEPTH=3
MODEL="knox"

# --- Sanitize: strip shell-breaking characters ---
sanitize() {
    echo "$1" | tr -d ':\\`<>|&;(){}[]$!' | tr '"' "'" | sed 's/  */ /g' | xargs
}

# --- Check if Knox/Ollama is actually online ---
check_online() {
    curl -sf http://localhost:11434/api/tags > /dev/null 2>&1
    return $?
}

# --- Detect if a prompt contains code (backticks or indentation) ---
contains_code() {
    echo "$1" | grep -qE '`|    [a-zA-Z]'
}

# --- Split prompt at natural language seams ---
# Returns array of parts via global SPLIT_PARTS
split_prompt() {
    local prompt="$1"
    SPLIT_PARTS=()

    # Try splitting on "and then", "also", ". ", "? ", "! "
    local delimiters=("and then" "also" ". " "? ")

    for delim in "${delimiters[@]}"; do
        if echo "$prompt" | grep -qi "$delim"; then
            local part1 part2
            part1=$(echo "$prompt" | sed "s/${delim}.*//i" | xargs)
            part2=$(echo "$prompt" | sed "s/.*${delim}//i" | xargs)
            if [ -n "$part1" ] && [ -n "$part2" ]; then
                SPLIT_PARTS=("$part1" "$part2")
                return 0
            fi
        fi
    done

    # No natural seam found — cannot split meaningfully
    return 1
}

# --- Classify whether two parts are dependent or independent ---
# Heuristic: if part2 starts with a pronoun or "it", "this", "that" — dependent
are_dependent() {
    local part2="$1"
    echo "$part2" | grep -qiE '^(it|this|that|then|after|once|if it|the result|use it|with it)'
}

# --- Run a single prompt against Knox ---
run_once() {
    local prompt="$1"
    local result
    result=$(timeout "$TIMEOUT" ollama run "$MODEL" "$prompt" 2>/dev/null)
    local code=$?
    if [ $code -eq 124 ]; then
        return 124  # timeout
    elif [ $code -ne 0 ] || [ -z "$result" ]; then
        return 1    # failed
    fi
    echo "$result"
    return 0
}

# --- Core recursive runner ---
PENDING_TASKS=()

run_prompt() {
    local prompt="$1"
    local depth="$2"
    local clean
    clean=$(sanitize "$prompt")

    if [ -z "$clean" ]; then
        echo "[knox-ask] Empty prompt, skipping."
        return 1
    fi

    # Hard stop: if code block detected, never split it
    if contains_code "$clean"; then
        echo "[knox-ask] Code detected — running as atomic task, no splitting."
        local result
        result=$(run_once "$clean")
        local code=$?
        if [ $code -eq 0 ]; then
            echo "$result"
            return 0
        else
            echo "[knox-ask] INCOMPLETE: Knox could not process this code block."
            PENDING_TASKS+=("$clean")
            return 1
        fi
    fi

    # Try running as-is
    local result
    result=$(run_once "$clean")
    local code=$?

    if [ $code -eq 0 ]; then
        echo "$result"
        return 0
    fi

    # Timeout or failure — check if Knox is even online
    if ! check_online; then
        echo "[knox-ask] Knox is offline. Run: knox-heal"
        exit 1
    fi

    # Knox is online but didn't respond — try splitting
    if [ "$depth" -ge "$MAX_DEPTH" ]; then
        echo "[knox-ask] INCOMPLETE: Could not resolve at max depth: $clean"
        PENDING_TASKS+=("$clean")
        return 1
    fi

    echo "[knox-ask] No response. Analyzing task structure..."

    split_prompt "$clean"
    if [ ${#SPLIT_PARTS[@]} -lt 2 ]; then
        echo "[knox-ask] INCOMPLETE: Cannot split further — single task Knox cannot resolve: $clean"
        PENDING_TASKS+=("$clean")
        return 1
    fi

    local part1="${SPLIT_PARTS[0]}"
    local part2="${SPLIT_PARTS[1]}"

    # Determine dependency
    if are_dependent "$part2"; then
        echo "[knox-ask] Tasks are DEPENDENT — part 2 relies on part 1. Running sequentially."
        echo ""
        echo "[knox-ask] Task 1 of 2: $part1"
        run_prompt "$part1" $(( depth + 1 ))
        local r1=$?
        if [ $r1 -ne 0 ]; then
            echo "[knox-ask] INCOMPLETE: Task 1 failed. Skipping dependent Task 2: $part2"
            PENDING_TASKS+=("$part2")
            return 1
        fi
        echo ""
        echo "[knox-ask] Task 2 of 2: $part2"
        run_prompt "$part2" $(( depth + 1 ))
    else
        echo "[knox-ask] Tasks are INDEPENDENT — running both."
        echo ""
        echo "[knox-ask] Task 1 of 2: $part1"
        run_prompt "$part1" $(( depth + 1 ))
        echo ""
        echo "[knox-ask] Task 2 of 2: $part2"
        run_prompt "$part2" $(( depth + 1 ))
    fi
}

# --- Entry point ---
if [ -z "$1" ]; then
    echo "Usage: knox-ask \"your question or task\""
    exit 1
fi

run_prompt "$1" 1

# --- Report anything still pending ---
if [ ${#PENDING_TASKS[@]} -gt 0 ]; then
    echo ""
    echo "=============================="
    echo "PENDING — Knox did not complete:"
    for task in "${PENDING_TASKS[@]}"; do
        echo "  - $task"
    done
    echo "=============================="
fi
