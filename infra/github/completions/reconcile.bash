# Optional: source infra/github/completions/reconcile.bash
# Completion is attached to a local function, not every python3 command.
mokaid-github-policy() { python3 infra/github/reconcile.py "$@"; }
_mokaid_github_policy_complete() {
    local current="${COMP_WORDS[COMP_CWORD]}"
    local previous="${COMP_WORDS[COMP_CWORD-1]}"
    local item
    COMPREPLY=()
    if [[ "$previous" == "--config" ]]; then
        while IFS= read -r item; do COMPREPLY+=("$item"); done < <(compgen -f -- "$current")
    elif [[ "$previous" == "--expect-plan" ]]; then
        COMPREPLY=()
    else
        while IFS= read -r item; do COMPREPLY+=("$item"); done < <(compgen -W '--plan --apply --expect-plan --config --help --version' -- "$current")
    fi
}
complete -F _mokaid_github_policy_complete mokaid-github-policy
