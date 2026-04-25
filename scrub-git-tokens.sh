#!/usr/bin/env bash
# Strip embedded credentials from github.com remote URLs in every git repo
# under $HOME. Run once per machine after `gh auth setup-git`. Idempotent.
set -u

fixed=0; checked=0
while IFS= read -r -d '' gitdir; do
  repo=$(dirname "$gitdir")
  checked=$((checked + 1))
  while IFS= read -r remote; do
    [ -z "$remote" ] && continue
    url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null) || continue
    if [[ "$url" =~ ^https://[^@/]+@github\.com/ ]]; then
      clean=$(echo "$url" | sed -E 's,https://[^@/]+@github\.com/,https://github.com/,')
      echo "fix: $repo  [$remote]"
      git -C "$repo" remote set-url "$remote" "$clean"
      fixed=$((fixed + 1))
    fi
  done < <(git -C "$repo" remote 2>/dev/null)
done < <(find "$HOME" -type d -name ".git" -print0 2>/dev/null)

echo "checked $checked repo(s); fixed $fixed remote URL(s)."
