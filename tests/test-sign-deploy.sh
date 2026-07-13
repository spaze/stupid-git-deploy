#!/usr/bin/env bash
set -u
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
sign_deploy=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/sign-deploy

# A repo with both values configured, the base for the validation cases below.
configured() {
	local repo
	repo=$(newrepo)
	git -C "$repo" config stupid-git-deploy.site ok.example
	git -C "$repo" config stupid-git-deploy.host web.example.com
	echo "$repo"
}

# For the cases that run past validation: an SSH signing key in local config, an
# origin to push the deploy tag to, and a stub that records the trigger instead
# of ssh'ing anywhere. deployable() returns such a repo, with HEAD at origin's
# tip so it neither warns nor blocks by default.
signer=$work/signer
ssh-keygen -t ed25519 -N '' -q -f "$signer"
signers=$work/allowed_signers
printf 'test@example %s\n' "$(awk '{print $1, $2}' "$signer.pub")" > "$signers"
mkdir --parents "$work/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/trigger.args"\n' "$work" > "$work/bin/trigger"
chmod +x "$work/bin/trigger"

deployable() {
	local repo bare
	repo=$(newrepo)
	git -C "$repo" config user.name test
	git -C "$repo" config user.email test@example
	git -C "$repo" config gpg.format ssh
	git -C "$repo" config user.signingkey "$signer"
	git -C "$repo" config stupid-git-deploy.site ok.example
	git -C "$repo" config stupid-git-deploy.host web.example.com
	bare=$(mktemp --directory "$work/deployable.XXXXXX")
	git init --quiet --bare --initial-branch=main "$bare"
	git -C "$repo" remote add origin "$bare"
	git -C "$repo" push --quiet origin HEAD:refs/heads/main
	echo "$repo"
}

testcase "No config and no argument: prints setup help"
repo=$(newrepo); out=$( cd "$repo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "No site configured for this repository" "$out" "says 'No site configured'"
contains "git config --local stupid-git-deploy.site <site>" "$out" "shows the git config command"
exits 2 "$exit_code" "exits 2"

testcase "Site from config, host missing: resolves site, asks for host"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site cfgsite.example
out=$( cd "$repo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "No deploy host configured for 'cfgsite.example'" "$out" "site came from config"
contains "git config --local stupid-git-deploy.host <[user@]host>" "$out" "host help shows [user@]host"
exits 2 "$exit_code" "exits 2"

testcase "Argument overrides the configured site"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site cfgsite.example
out=$( cd "$repo" && bash "$sign_deploy" argsite.example 2>&1 )
exit_code=$?
contains "No deploy host configured for 'argsite.example'" "$out" "argument wins over config"
exits 2 "$exit_code" "exits 2"

testcase "A fully configured repo signs the tag, pushes it, and triggers the host"
repo=$(deployable)
out=$( cd "$repo" && STUPID_GIT_DEPLOY_SSH="$work/bin/trigger" bash "$sign_deploy" 2>&1 )
exit_code=$?
exits 0 "$exit_code" "sign-deploy completes"
contains "Good" "$(git -C "$repo" -c gpg.ssh.allowedSignersFile="$signers" tag --verify deploy 2>&1)" "deploy tag is signed by the authorized key"
contains "refs/tags/deploy" "$(git -C "$repo" ls-remote origin)" "deploy tag pushed to origin"
trigger=$(cat "$work/trigger.args")
contains "ok.example" "$trigger" "triggered the host with the site"
contains "$(git -C "$repo" rev-parse HEAD)" "$trigger" "triggered with the signed commit SHA"

testcase "Invalid site from config is rejected"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site 'bad!name'
out=$( cd "$repo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Invalid site name 'bad!name'" "$out" "invalid site rejected"
exits 2 "$exit_code" "exits 2"

testcase "Leading-dash host is rejected (option injection)"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site ok.example; git -C "$repo" config stupid-git-deploy.host '-oProxyCommand=x'
out=$( cd "$repo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "must not start with '-'" "$out" "leading-dash host rejected"
exits 2 "$exit_code" "exits 2"

testcase "STUPID_GIT_DEPLOY_HOST overrides the configured host"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site ok.example; git -C "$repo" config stupid-git-deploy.host goodhost.example
out=$( cd "$repo" && STUPID_GIT_DEPLOY_HOST=-envbad bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Invalid host '-envbad'" "$out" "env host used, not config"
exits 2 "$exit_code" "exits 2"

testcase "Whitespace host is rejected before the trigger"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site ok.example; git -C "$repo" config stupid-git-deploy.host "   "
out=$( cd "$repo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "must not contain whitespace" "$out" "whitespace host (config) rejected"
exits 2 "$exit_code" "exits 2"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site ok.example
out=$( cd "$repo" && STUPID_GIT_DEPLOY_HOST="   " bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "must not contain whitespace" "$out" "whitespace host (env) rejected"
exits 2 "$exit_code" "exits 2"
repo=$(newrepo); git -C "$repo" config stupid-git-deploy.site ok.example; git -C "$repo" config stupid-git-deploy.host "web.example.com x"
out=$( cd "$repo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "must not contain whitespace" "$out" "internal-whitespace host rejected"
exits 2 "$exit_code" "exits 2"

testcase "Invalid STUPID_GIT_DEPLOY_TAG is rejected"
repo=$(configured)
out=$( cd "$repo" && STUPID_GIT_DEPLOY_TAG=-bad bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Invalid STUPID_GIT_DEPLOY_TAG" "$out" "bad tag rejected"
exits 2 "$exit_code" "exits 2"

testcase "Invalid STUPID_GIT_DEPLOY_REMOTE is rejected"
repo=$(configured)
out=$( cd "$repo" && STUPID_GIT_DEPLOY_REMOTE='a b' bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Invalid STUPID_GIT_DEPLOY_REMOTE" "$out" "bad remote rejected"
exits 2 "$exit_code" "exits 2"

testcase "Invalid STUPID_GIT_DEPLOY_SSH is rejected"
repo=$(configured)
out=$( cd "$repo" && STUPID_GIT_DEPLOY_SSH=-bad bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Invalid STUPID_GIT_DEPLOY_SSH" "$out" "bad ssh command rejected"
exits 2 "$exit_code" "exits 2"

testcase "Outside a Git repository: errors first"
nonrepo=$(mktemp --directory "$work/nonrepo.XXXXXX")
out=$( cd "$nonrepo" && bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Not a Git repository" "$out" "not-a-repo message"
exits 2 "$exit_code" "exits 2"

testcase "A global git config value does not leak past --local"
repo=$(newrepo); home=$(mktemp --directory "$work/home.XXXXXX")
HOME="$home" git config --global stupid-git-deploy.site globalsite.example
HOME="$home" git config --global stupid-git-deploy.host globalhost.example
out=$( cd "$repo" && HOME="$home" bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "No site configured" "$out" "global site ignored (no local)"
exits 2 "$exit_code" "exits 2"
git -C "$repo" config stupid-git-deploy.site local.example
out=$( cd "$repo" && HOME="$home" bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "No deploy host configured for 'local.example'" "$out" "global host ignored (local site set)"
exits 2 "$exit_code" "exits 2"

testcase "Warns but still deploys when the working tree is dirty"
repo=$(deployable); touch "$repo/uncommitted"
out=$( cd "$repo" && STUPID_GIT_DEPLOY_SSH="$work/bin/trigger" bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Working tree is dirty" "$out" "dirty-tree warning fires"
exits 0 "$exit_code" "warns but does not block"

testcase "Warns but still deploys when HEAD is not at origin's default branch"
repo=$(deployable)
git -C "$repo" -c user.name=test -c user.email=test@example commit --quiet --allow-empty --message ahead
git -C "$repo" fetch --quiet origin
out=$( cd "$repo" && STUPID_GIT_DEPLOY_SSH="$work/bin/trigger" bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "HEAD is not at origin/" "$out" "off-branch warning fires"
exits 0 "$exit_code" "warns but does not block"

testcase "An unreachable deploy host is caught before the tag moves"
repo=$(deployable)
out=$( cd "$repo" && STUPID_GIT_DEPLOY_SSH=false bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "Cannot reach the deploy host" "$out" "pre-flight failure reported"
exits 1 "$exit_code" "exits non-zero"
tagref=$(git -C "$repo" rev-parse --verify --quiet refs/tags/deploy || echo none)
contains "none" "$tagref" "deploy tag was not created (nothing moved)"

testcase "A failed deploy after a reachable host is reported, with the tag already pushed"
repo=$(deployable)
# shellcheck disable=SC2016 # $2 is the stub's own arg, expanded when the stub runs
printf '#!/bin/sh\ncase "$2" in true) exit 0 ;; *) echo boom >&2; exit 1 ;; esac\n' > "$work/bin/flaky"
chmod +x "$work/bin/flaky"
out=$( cd "$repo" && STUPID_GIT_DEPLOY_SSH="$work/bin/flaky" bash "$sign_deploy" 2>&1 )
exit_code=$?
contains "did not succeed" "$out" "deploy failure reported clearly"
exits 1 "$exit_code" "exits non-zero"
contains "refs/tags/deploy" "$(git -C "$repo" ls-remote origin)" "tag was still pushed (authorization recorded)"

summary
