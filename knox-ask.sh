#!/bin/bash
TIMEOUT=120
MAX_DEPTH=2
MIN_WORDS_TO_SPLIT=12
MODEL="knox"
PENDING_TASKS=()

sanitize() {
    echo "$1" | tr -d ':\\`<>|{}[]$!' | tr '"' "'" | sed 's/  */ /g' | xargs
}

check_online() {
    curl -sf http://localhost:11434/api/tags > /dev/null 2>&1
}

contains_code() {
    echo "$1" | grep -qE '`|    [a-zA-Z]'
}

split_prompt() {
    local prompt="$1"
    SPLIT_PARTS=()
    local delimiters=("and then" "also" "and confirm" "and check" "and restart" "and verify")
    for delim in "${delimiters[@]}"; do
        if echo "$prompt" | grep -qi " $delim "; then
            local part1 part2
            part1=$(echo "$prompt" | awk -v d="$delim" 'BEGIN{IGNORECASE=1}{n=index(tolower($0),tolower(" " d " ")); if(n>0) print substr($0,1,n-1)}' | xargs)
            part2=$(echo "$prompt" | awk -v d="$delim" 'BEGIN{IGNORECASE=1}{n=index(tolower($0),tolower(" " d " ")); if(n>0) print substr($0,n+length(d)+2)}' | xargs)
            if [ -n "$part1" ] && [ -n "$part2" ]; then
                SPLIT_PARTS=("$part1" "$part2")
                return 0
            fi
        fi
    done
    return 1
}

are_dependent() {
    echo "$1" | grep -qiE '^(it|this|that|then|after|once|if it|the result|use it|with it)'
}

run_once() {
    local result
    result=$(timeout "$TIMEOUT" ollama run "$MODEL" "$1" 2>/dev/null)
    local code=$?
    [ $code -eq 0 ] && [ -n "$result" ] && echo "$result" && return 0
    return $code
}

run_prompt() {
    local prompt="$1"
    local depth="$2"
    local clean
    clean=$(sanitize "$prompt")
    [ -z "$clean" ] && return 1

    if contains_code "$clean"; then
        local result
        result=$(run_once "$clean")
        [ $? -eq 0 ] && echo "$result" && return 0
        echo "[knox-ask] INCOMPLETE: $clean"
        PENDING_TASKS+=("$clean")
        return 1
    fi

    local result
    result=$(run_once "$clean")
    [ $? -eq 0 ] && echo "$result" && return 0

    if ! check_online; then
        echo "[knox-ask] Knox is offline. Run: knox-heal"
        exit 1
    fi

    # Don't try to split short prompts — just report incomplete
    local word_count
    word_count=$(echo "$clean" | wc -w)
    if [ "$word_count" -lt "$MIN_WORDS_TO_SPLIT" ]; then
        echo "[knox-ask] INCOMPLETE: Knox timed out. Task is simple — Knox may be busy. Try again."
        PENDING_TASKS+=("$clean")
        return 1
    fi

    [ "$depth" -ge "$MAX_DEPTH" ] && echo "[knox-ask] INCOMPLETE: $clean" && PENDING_TASKS+=("$clean") && return 1

    echo "[knox-ask] No response. Analyzing task structure..."
    split_prompt "$clean"

    if [ ${#SPLIT_PARTS[@]} -lt 2 ]; then
        echo "[knox-ask] INCOMPLETE: Cannot split further: $clean"
        PENDING_TASKS+=("$clean")
        return 1
    fi

    local part1="${SPLIT_PARTS[0]}"
    local part2="${SPLIT_PARTS[1]}"

    if are_dependent "$part2"; then
        echo "[knox-ask] Dependent tasks — running sequentially."
        echo "[knox-ask] Task 1: $part1"
        run_prompt "$part1" $(( depth + 1 )) || { echo "[knox-ask] INCOMPLETE: $part2"; PENDING_TASKS+=("$part2"); return 1; }
        echo "[knox-ask] Task 2: $part2"
        run_prompt "$part2" $(( depth + 1 ))
    else
        echo "[knox-ask] Independent tasks — running both."
        echo "[knox-ask] Task 1: $part1"
        run_prompt "$part1" $(( depth + 1 ))
        echo "[knox-ask] Task 2: $part2"
        run_prompt "$part2" $(( depth + 1 ))
    fi
}

[ -z "$1" ] && echo "Usage: knox-ask \"your question\"" && exit 1
run_prompt "$1" 1

if [ ${#PENDING_TASKS[@]} -gt 0 ]; then
    echo ""
    echo "=============================="
    echo "PENDING — not completed:"
    for task in "${PENDING_TASKS[@]}"; do echo "  - $task"; done
    echo "=============================="
fi
