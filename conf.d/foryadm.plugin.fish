# MIT (c) Chris Apple

function forgit::warn
    printf "%b[Warn]%b %s\n" '\e[0;33m' '\e[0m' "$argv" >&2;
end

function forgit::info
    printf "%b[Info]%b %s\n" '\e[0;32m' '\e[0m' "$argv" >&2;
end

function forgit::inside_work_tree
    git rev-parse --is-inside-work-tree >/dev/null;
end

set -g forgit_pager        "$FORGIT_PAGER"
set -g forgit_show_pager   "$FORGIT_SHOW_PAGER"
set -g forgit_diff_pager   "$FORGIT_DIFF_PAGER"
set -g forgit_ignore_pager "$FORGIT_IGNORE_PAGER"
set -g forgit_log_format   "$FORGIT_LOG_FORMAT"

test -z "$forgit_pager";        and set -g forgit_pager        (git config core.pager || echo 'cat')
test -z "$forgit_show_pager";   and set -g forgit_show_pager   (git config pager.show || echo "$forgit_pager")
test -z "$forgit_diff_pager";   and set -g forgit_diff_pager   (git config pager.diff || echo "$forgit_pager")
test -z "$forgit_ignore_pager"; and set -g forgit_ignore_pager (type -q bat >/dev/null 2>&1 && echo 'bat -l gitignore --color=always' || echo 'cat')
test -z "$forgit_log_format";   and set -g forgit_log_format   "-%C(auto)%h%d %s %C(black)%C(bold)%cr%Creset"

# https://github.com/wfxr/emoji-cli
type -q emojify >/dev/null 2>&1 && set -g forgit_emojify '|emojify'

# git commit viewer
function forgit::log -d "git commit viewer"
    forgit::inside_work_tree || return 1

    set files (echo $argv | sed -nE 's/.* -- (.*)/\1/p')
    set cmd "echo {} |grep -Eo '[a-f0-9]+' |head -1 |xargs -I% git show --color=always % -- $files | $forgit_show_pager"

    if test -n "$FORGIT_COPY_CMD"
        set copy_cmd $FORGIT_COPY_CMD
    else
        set copy_cmd pbcopy
    end

    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +s +m --tiebreak=index
        --bind=\"enter:execute($cmd |env LESS='-r' less)\"
        --bind=\"ctrl-y:execute-silent(echo {} |grep -Eo '[a-f0-9]+' | head -1 | tr -d '[:space:]' |$copy_cmd)\"
        $FORGIT_LOG_FZF_OPTS
    "

    if set -q FORGIT_LOG_GRAPH_ENABLE
        set graph "--graph"
    else
        set graph ""
    end

    eval "git log $graph --color=always --format='$forgit_log_format' $argv $forgit_emojify" |
        env FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd"
end

## git diff viewer
function forgit::diff -d "git diff viewer" 
    forgit::inside_work_tree || return 1
    if count $argv > /dev/null
        if git rev-parse "$1" > /dev/null 2>&1
            set commit "$1" && set files "$2"
        else
            set files "$argv"
        end
    end

    set repo (git rev-parse --show-toplevel)
    set cmd "echo {} |sed 's/.*]  //' | xargs -I% git diff --color=always $commit -- '$repo/%' | $forgit_diff_pager"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +m -0 --bind=\"enter:execute($cmd |env LESS='-r' less)\"
        $FORGIT_DIFF_FZF_OPTS
    "

    eval "git diff --name-only $commit -- $files*| sed -E 's/^(.)[[:space:]]+(.*)\$/[\1]  \2/'" | env FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd"
end

# git add selector
function forgit::add -d "git add selector"
    forgit::inside_work_tree || return 1
    # Add files if passed as arguments
    count $argv >/dev/null && git add "$argv" && git status --short && return

    set changed (git config --get-color color.status.changed red)
    set unmerged (git config --get-color color.status.unmerged red)
    set untracked (git config --get-color color.status.untracked red)

    set extract_file "
        sed 's/^[[:space:]]*//' |           # remove leading whitespace
        cut -d ' ' -f 2- |                  # cut the line after the M or ??, this leaves just the filename
        sed 's/.* -> //' |                  # for rename case
        sed -e 's/^\\\"//' -e 's/\\\"\$//'  # removes surrounding quotes
    "
    set preview "
        set file (echo {} | $extract_file)
        # exit
        if test (yadm status -s -- \$file | grep '^??') # diff with /dev/null for untracked files
            yadm diff --color=always --no-index -- /dev/null \$file | $foryadm_diff_pager | sed '2 s/added:/untracked:/'
        else
            yadm diff --color=always -- \$file | $foryadm_diff_pager
        end
        "
    set opts "
        $FORYADM_FZF_DEFAULT_OPTS
        -0 -m --nth 2..,..
        $FORYADM_ADD_FZF_OPTS
    "
    set files (yadm -c color.status=always -c status.relativePaths=true status -s --untracked=normal |
        grep -F -e "$changed" -e "$unmerged" -e "$untracked" |
        sed -E 's/^(..[^[:space:]]*)[[:space:]]+(.*)\$/[\1]  \2/' |   # deal with white spaces internal to fname
        env FZF_DEFAULT_OPTS="$opts" fzf --preview="$preview" |
        sh -c "$extract_file") # for rename case

    if test -n "$files"
        for file in $files
            echo $file | tr '\n' '\0' | xargs -I{} -0 git add {}
        end
        git status --short
        return
    end
    echo 'Nothing to add.'
end

## git reset HEAD (unstage) selector
function forgit::reset::head -d "git reset HEAD (unstage) selector"
    forgit::inside_work_tree || return 1
    set cmd "git diff --cached --color=always -- {} | $forgit_diff_pager"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        -m -0
        $FORGIT_RESET_HEAD_FZF_OPTS
    "
    set files (git diff --cached --name-only --relative | env FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd")
    if test -n "$files"
        for file in $files
            echo $file | tr '\n' '\0' |xargs -I{} -0 git reset -q HEAD {}
        end
        git status --short
        return
    end
    echo 'Nothing to unstage.'
end

# git checkout-restore selector
function forgit::checkout::file -d "git checkout-file selector" --argument-names 'file_name'
    forgit::inside_work_tree || return 1

    if test -n "$file_name"
        git checkout -- "$file_name"
        set checkout_status $status
        git status --short
        return $checkout_status
    end


    set cmd "git diff --color=always -- {} | $forgit_diff_pager"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        -m -0
        $FORGIT_CHECKOUT_FILE_FZF_OPTS
    "
    set git_rev_parse (git rev-parse --show-toplevel)
    set files (git ls-files --modified "$git_rev_parse" | env FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd")

    if test -n "$files"
        for file in $files
            echo $file | tr '\n' '\0' | xargs -I{} -0 git checkout -q {}
        end
        git status --short
        return
    end
    echo 'Nothing to restore.'
end

function forgit::checkout::commit -d "git checkout commit selector" --argument-names 'commit_id'
    forgit::inside_work_tree || return 1

    if test -n "$commit_id"
        git checkout "$commit_id"
        set checkout_status $status
        git status --short
        return $checkout_status
    end

    if test -n "$FORGIT_COPY_CMD"
        set copy_cmd $FORGIT_COPY_CMD
    else
        set copy_cmd pbcopy
    end


    set cmd "echo {} |grep -Eo '[a-f0-9]+' |head -1 |xargs -I% git show --color=always % | $forgit_show_pager"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +s +m --tiebreak=index
        --bind=\"ctrl-y:execute-silent(echo {} |grep -Eo '[a-f0-9]+' | head -1 | tr -d '[:space:]' | $copy_cmd)\"
        $FORGIT_COMMIT_FZF_OPTS
    "

    if set -q FORGIT_LOG_GRAPH_ENABLE
        set graph "--graph"
    else
        set graph ""
    end

    eval "git log $graph --color=always --format='$forgit_log_format' $forgit_emojify" |
        FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd" |grep -Eo '[a-f0-9]+' |head -1 |xargs -I% git checkout % --
end


function forgit::checkout::branch -d "git checkout branch selector" --argument-names 'branch_name'
    forgit::inside_work_tree || return 1

    if test -n "$branch_name"
        git checkout -b "$branch_name"
        set checkout_status $status
        git status --short
        return $checkout_status
    end

    set cmd "git branch --color=always --verbose --all --format=\"%(if:equals=HEAD)%(refname:strip=3)%(then)%(else)%(refname:short)%(end)\" $argv $forgit_emojify | sed '/^\$/d'"
    set preview "git log {} --graph --pretty=format:'$forgit_log_format' --color=always --abbrev-commit --date=relative"

    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +s +m --tiebreak=index 
        $FORGIT_CHECKOUT_BRANCH_FZF_OPTS
        "
    eval "$cmd" | env FZF_DEFAULT_OPTS="$opts" fzf --preview="$preview" | xargs -I% git checkout %
end

# git stash viewer
function forgit::stash::show -d "git stash viewer"
    forgit::inside_work_tree || return 1
    set cmd "echo {} |cut -d: -f1 |xargs -I% git stash show --color=always --ext-diff % |$forgit_diff_pager"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +s +m -0 --tiebreak=index --bind=\"enter:execute($cmd |env LESS='-r' less)\"
        $FORGIT_STASH_FZF_OPTS
    "
    git stash list | env FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd"
end

# git clean selector
function forgit::clean -d "git clean selector"
    forgit::inside_work_tree || return 1

    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        -m -0
        $FORGIT_CLEAN_FZF_OPTS
    "

    set files (git clean -xdffn $argv| awk '{print $3}'| env FZF_DEFAULT_OPTS="$opts" fzf |sed 's#/$##')

    if test -n "$files"
        for file in $files
            echo $file | tr '\n' '\0'| xargs -0 -I{} git clean -xdff {}
        end
        git status --short
        return
    end
    echo 'Nothing to clean.'
end

function forgit::cherry::pick -d "git cherry-picking" --argument-names 'target'
    forgit::inside_work_tree || return 1
    set base (git branch --show-current)
    if test -n "$target"
        echo "Please specify target branch"
        return 1
    end
    set preview "echo {1} | xargs -I% git show --color=always % | $forgit_show_pager"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        -m -0
    "
    echo $base
    echo $target
    git cherry "$base" "$target" --abbrev -v | cut -d ' ' -f2- |
        env FZF_DEFAULT_OPTS="$opts" fzf --preview="$preview" | cut -d' ' -f1 |
        xargs -I% git cherry-pick %
end

function forgit::fixup -d "git fixup"
    forgit::inside_work_tree || return 1
    git diff --cached --quiet && echo 'Nothing to fixup: there are no staged changes.' && return 1

    if set -q FORGIT_LOG_GRAPH_ENABLE
        set graph "--graph"
    else
        set graph ""
    end

    set cmd "git log $graph --color=always --format='$forgit_log_format' $argv $forgit_emojify"
    set files (echo $argv | sed -nE 's/.* -- (.*)/\1/p')
    set preview "echo {} |grep -Eo '[a-f0-9]+' |head -1 |xargs -I% git show --color=always % -- $files | $forgit_show_pager"

    if test -n "$FORGIT_COPY_CMD"
        set copy_cmd $FORGIT_COPY_CMD
    else
        set copy_cmd pbcopy
    end

    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +s +m --tiebreak=index
        --bind=\"ctrl-y:execute-silent(echo {} |grep -Eo '[a-f0-9]+' | head -1 | tr -d '[:space:]' |$copy_cmd)\"
        $FORGIT_FIXUP_FZF_OPTS
    "

    set target_commit (eval "$cmd" | FZF_DEFAULT_OPTS="$opts" fzf --preview="$preview" | grep -Eo '[a-f0-9]+' | head -1)

    if test -n "$target_commit" && git commit --fixup "$target_commit"
        # "$target_commit~" is invalid when the commit is the first commit, but we can use "--root" instead
        set prev_commit "$target_commit~"
        if test "(git rev-parse '$target_commit')" = "(git rev-list --max-parents=0 HEAD)"
            set prev_commit "--root"
        end

        GIT_SEQUENCE_EDITOR=: git rebase --autostash -i --autosquash "$prev_commit"
    end

end


function forgit::rebase -d "git rebase"
    forgit::inside_work_tree || return 1

    if set -q FORGIT_LOG_GRAPH_ENABLE
        set graph "--graph"
    else
        set graph ""
    end
    set cmd "git log $graph --color=always --format='$forgit_log_format' $argv $forgit_emojify"

    set files (echo $argv | sed -nE 's/.* -- (.*)/\1/p')
    set preview "echo {} |grep -Eo '[a-f0-9]+' |head -1 |xargs -I% git show --color=always % -- $files | $forgit_show_pager"

    if test -n "$FORGIT_COPY_CMD"
        set copy_cmd $FORGIT_COPY_CMD
    else
        set copy_cmd pbcopy
    end

    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        +s +m --tiebreak=index
        --bind=\"ctrl-y:execute-silent(echo {} |grep -Eo '[a-f0-9]+' | head -1 | tr -d '[:space:]' |$copy_cmd)\"
        $FORGIT_REBASE_FZF_OPTS
    "
    set commit (eval "$cmd" | FZF_DEFAULT_OPTS="$opts" fzf --preview="$preview" |
        grep -Eo '[a-f0-9]+' | head -1)

    if test $commit
        git rebase -i "$commit"
    end
end

# git ignore generator
if test -z "$FORGIT_GI_REPO_REMOTE"
    set -g FORGIT_GI_REPO_REMOTE https://github.com/dvcs/gitignore
end

if test -z "$FORGIT_GI_REPO_LOCAL"
    if test "XDG_CACHE_HOME"
        set -g FORGIT_GI_REPO_LOCAL $XDG_CACHE_HOME/forgit/gi/repos/dvcs/gitignore
    else
        set -g FORGIT_GI_REPO_LOCAL $HOME/.cache/forgit/gi/repos/dvcs/gitignore
    end
end

if test -z "$FORGIT_GI_TEMPLATES"
    set -g FORGIT_GI_TEMPLATES $FORGIT_GI_REPO_LOCAL/templates
end

function forgit::ignore -d "git ignore generator"
    if not test -d "$FORGIT_GI_REPO_LOCAL"
        forgit::ignore::update
    end

    set cmd "$forgit_ignore_pager $FORGIT_GI_TEMPLATES/{2}{,.gitignore} 2>/dev/null"
    set opts "
        $FORGIT_FZF_DEFAULT_OPTS
        -m --preview-window='right:70%'
        $FORGIT_IGNORE_FZF_OPTS
    "
    set IFS '\n'

    set args $argv
    if not count $argv > /dev/null
        set args (forgit::ignore::list | nl -nrn -w4 -s'  ' |
        env FZF_DEFAULT_OPTS="$opts" fzf --preview="$cmd"  |awk '{print $2}')
    end

     if not count $args > /dev/null
         return 1
     end

     foryadm::ignore::get $args
end

function foryadm::ignore::update
    if test -d "$FORYADM_GI_REPO_LOCAL"
        foryadm::info 'Updating gitignore repo...'
        set pull_result (yadm -C "$FORYADM_GI_REPO_LOCAL" pull --no-rebase --ff)
        test -n "$pull_result" || return 1
    else
        foryadm::info 'Initializing gitignore repo...'
        yadm clone --depth=1 "$FORYADM_GI_REPO_REMOTE" "$FORYADM_GI_REPO_LOCAL"
    end
end

function foryadm::ignore::get
    for item in $argv
        set filename (find -L "$FORYADM_GI_TEMPLATES" -type f \( -iname "$item.gitignore" -o -iname "$item}" \) -print -quit)
        if test -n "$filename"
            set header $filename && set header (echo $filename | sed 's/.*\.//')
            echo "### $header" && cat "$filename" && echo
        else
            foryadm::warn "No gitignore template found for '$item'." && continue
        end
    end
end

function foryadm::ignore::list
    find "$FORYADM_GI_TEMPLATES" -print |sed -e 's#.gitignore$##' -e 's#.*/##' | sort -fu
end

function foryadm::ignore::clean
    setopt localoptions rmstarsilent
    [[ -d "$FORYADM_GI_REPO_LOCAL" ]] && rm -rf "$FORYADM_GI_REPO_LOCAL"
end

set -g FORYADM_FZF_DEFAULT_OPTS "
$FZF_DEFAULT_OPTS
--ansi
--height='80%'
--bind='alt-k:preview-up,alt-p:preview-up'
--bind='alt-j:preview-down,alt-n:preview-down'
--bind='ctrl-r:toggle-all'
--bind='ctrl-s:toggle-sort'
--bind='?:toggle-preview'
--bind='alt-w:toggle-preview-wrap'
--preview-window='right:60%'
+1
$FORYADM_FZF_DEFAULT_OPTS
"

# register aliases
if test -z "$FORYADM_NO_ALIASES"
    if test -n "$foryadm_add"
        alias $foryadm_add 'foryadm::add'
    else
        alias yadd 'foryadm::add'
    end

    if test -n "$foryadm_reset_head"
        alias $foryadm_reset_head 'foryadm::reset::head'
    else
        alias yadrh 'foryadm::reset::head'
    end

    if test -n "$foryadm_log"
        alias $foryadm_log 'foryadm::log'
    else
        alias yadlo 'foryadm::log'
    end

    if test -n "$foryadm_diff"
        alias $foryadm_diff 'foryadm::diff'
    else
        alias yadiff 'foryadm::diff'
    end

    if test -n "$foryadm_ignore"
        alias $foryadm_ignore 'foryadm::ignore'
    else
        alias yadi 'foryadm::ignore'
    end

    if test -n "$foryadm_checkout_file"
        alias $foryadm_checkout_file 'foryadm::checkout::file'
    else
        alias yadcf 'foryadm::checkout::file'
    end

    if test -n "$foryadm_checkout_branch"
        alias $foryadm_branch 'foryadm::checkout::branch'
    else
        alias yadcb 'foryadm::checkout::branch'
    end

    if test -n "$foryadm_clean"
        alias $foryadm_clean 'foryadm::clean'
    else
        alias yadclean 'foryadm::clean'
    end

    if test -n "$foryadm_stash_show"
        alias $foryadm_stash_show 'foryadm::stash::show'
    else
        alias yadss 'foryadm::stash::show'
    end

    if test -n "$foryadm_cherry_pick"
        alias $foryadm_cherry_pick 'foryadm::cherry::pick'
    else
        alias yadcp 'foryadm::cherry::pick'
    end

    if test -n "$foryadm_rebase"
        alias $foryadm_rebase 'foryadm::rebase'
    else
        alias yadrb 'foryadm::rebase'
    end

    if test -n "$foryadm_fixup"
        alias $foryadm_fixup 'foryadm::fixup'
    else
        alias yadfu 'foryadm::fixup'
    end

    if test -n "$foryadm_checkout_commit"
        alias $foryadm_checkout_commit 'foryadm::checkout::commit'
    else
        alias yadco 'foryadm::checkout::commit'
    end

end
