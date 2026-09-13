# Optional from the repository root: source infra/github/completions/reconcile.zsh
mokaid-github-policy() { python3 infra/github/reconcile.py "$@"; }
_mokaid_github_policy() {
    _arguments \
        '(--apply)--plan[Read-only plan (default)]' \
        '(--plan)--apply[Apply the reviewed plan]' \
        '--expect-plan[Reviewed plan SHA256]:digest:' \
        '--config[Reviewed non-secret JSON]:configuration:_files -g "*.json"' \
        '--help[Show help]' '--version[Show version]'
}
compdef _mokaid_github_policy mokaid-github-policy
