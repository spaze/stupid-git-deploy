# stupid-git-deploy

## Installation
Create the following symlinks:
1. `~/.local/bin/deploy` (or `~/bin/deploy`) that points to `deploy`
2. `~/.local/bin/git_ssh_wrapper` (or `~/bin/git_ssh_wrapper`) that points to `git_ssh_wrapper`
3. `~/.local/share/bash-completion/completions/deploy` that points to `deploy_bash_completion` – the symlink's filename has to be `deploy`, otherwise the completion won't work
