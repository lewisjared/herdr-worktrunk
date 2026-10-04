#!/usr/bin/env bash
# Clean-up for the worktrunk herdr plugin: multi-select removable worktrees, then
# `wt remove` each one. Plain bash, shell-agnostic: it calls the `wt` binary directly,
# so it needs no shell-function/rc integration.

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"
# shellcheck source=./lifecycle.sh
source "$plugin_root/lifecycle.sh"

worktrunk_fzf_layout

wtitems=$(worktrunk_worktree_items) || exit 1

# One "branch<TAB>path" line per removable worktree. The path is the identity, so
# detached worktrees and duplicate branch names stay unambiguous.
cands=$(printf '%s\n' "$wtitems" \
  | jq -r 'select(.kind == "worktree" and .path != null and .is_main != true)
      | [(.branch // "(detached)"), .path] | @tsv')
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No removable worktrees (only the main worktree exists)."; sleep 2; exit 0
fi

selected=$(printf '%s\n' "$cands" \
  | worktrunk_pick_branch 'clean worktrees ❯ ' \
      'tab to select · ↵ removes them (worktrunk will ask to confirm) · esc to cancel' \
      --multi --delimiter=$'\t' --with-nth=1)
[[ -z $selected ]] && exit 0      # esc / no selection → cancel

names=() paths=() wsids=()
while IFS=$'\t' read -r name wtpath; do
  [[ -z $wtpath ]] && continue
  names+=("$name")
  paths+=("$wtpath")
  # Resolve every workspace up front: herdr forgets the mapping with the worktree,
  # and the pane's own cwd may be one of the worktrees about to go.
  wsids+=("$(worktrunk_open_workspace_id "$wtpath")")
done <<<"$selected"

mainpath=$(printf '%s\n' "$wtitems" | worktrunk_main_worktree_path)

# wt remove prompts for approval itself, refuses unmerged branches without -D, and
# refuses worktrees with untracked files without -f, so let worktrunk gate each one.
# --foreground keeps the pane until it's done. -C runs it from the main worktree.
removed=() failed=()
for i in "${!paths[@]}"; do
  if wt remove --foreground -C "$mainpath" "${paths[$i]}"; then
    removed+=("$i")
  else
    failed+=("${names[$i]}")
  fi
done

if ((${#failed[@]})); then
  printf '\n\033[31m%s\033[0m\n' "wt remove failed (see above). Kept:"
  printf '  %s\n' "${failed[@]}"
  printf 'press any key to close'; read -r -n1
elif ((${#removed[@]})); then
  worktrunk_hold_pane remove "removed ${names[*]}."
fi

# Close workspaces only after every removal has run, and the picker's own workspace
# last: closing it earlier would kill the batch halfway through.
close_current=false
for i in "${removed[@]}"; do
  if [[ -n ${wsids[$i]} && ${wsids[$i]} == "${HERDR_WORKSPACE_ID:-}" ]]; then
    close_current=true
  else
    worktrunk_close_worktree_ui "${wsids[$i]}" "${paths[$i]}"
  fi
done
if [[ $close_current == true ]]; then
  worktrunk_close_worktree_ui "$HERDR_WORKSPACE_ID" ""
fi
