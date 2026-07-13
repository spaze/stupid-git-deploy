#!/usr/bin/env bash
set -u
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
deploy=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/deploy

# Input validation: the guards that run before flock.
root=$(mktemp --directory "$work/root.XXXXXX"); mkdir "$root/site-a" "$root/site-b"

testcase "No argument: usage lists the available sites"
out=$( STUPID_GIT_DEPLOY_ROOT="$root" bash "$deploy" 2>&1 )
contains "<site> is one of:" "$out" "shows the site-list header"
contains "site-a" "$out" "lists a site directory"

testcase "Invalid site name is rejected"
out=$( STUPID_GIT_DEPLOY_ROOT="$root" bash "$deploy" 'bad!name' 2>&1 )
exit_code=$?
contains "Invalid site name 'bad!name'" "$out" "invalid site rejected"
exits 2 "$exit_code" "exits 2"

testcase "Unsafe STUPID_GIT_DEPLOY_ROOT is rejected"
out=$( STUPID_GIT_DEPLOY_ROOT="-evil" bash "$deploy" site-a 2>&1 )
exit_code=$?
contains "Unsafe STUPID_GIT_DEPLOY_ROOT" "$out" "unsafe root rejected"
exits 2 "$exit_code" "exits 2"

testcase "Unsafe STUPID_GIT_DEPLOY_TAG is rejected"
out=$( STUPID_GIT_DEPLOY_ROOT="$root" STUPID_GIT_DEPLOY_TAG="-evil" bash "$deploy" site-a 2>&1 )
exit_code=$?
contains "Unsafe STUPID_GIT_DEPLOY_TAG" "$out" "unsafe tag rejected"
exits 2 "$exit_code" "exits 2"

testcase "A site that does not exist is rejected"
out=$( STUPID_GIT_DEPLOY_ROOT="$root" bash "$deploy" nosuchsite 2>&1 )
exit_code=$?
contains "Site nosuchsite doesn't exist" "$out" "missing site rejected"
exits 2 "$exit_code" "exits 2"

# Security core: signature verification, fast-forward, SHA pin. Offline fixture:
# a bare origin (c1 -> c2 on main), a throwaway ssh signing key with an
# allowed_signers, and a per-test site checkout cloned from that origin.
ssh-keygen -t ed25519 -N '' -q -f "$work/id"
ssh-keygen -t ed25519 -N '' -q -f "$work/foreign"
signers=$work/allowed_signers
printf 'test@example %s\n' "$(awk '{print $1, $2}' "$work/id.pub")" > "$signers"

# Stub curl so the deploy healthcheck never touches the network.
mkdir --parents "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/curl"
chmod +x "$work/bin/curl"

siteroot=$(mktemp --directory "$work/siteroot.XXXXXX")
origin=$work/origin.git
git init --quiet --bare --initial-branch=main "$origin"
build=$work/build
git init --quiet "$build"
git -C "$build" remote add origin "$origin"

git_build() {
	git -C "$build" -c user.name=test -c user.email=test@example "$@"
}

git_build commit --quiet --allow-empty --message c1
git_build push --quiet origin HEAD:refs/heads/main
c1=$(git_build rev-parse HEAD)
git_build commit --quiet --allow-empty --message c2
git_build push --quiet origin HEAD:refs/heads/main
c2=$(git_build rev-parse HEAD)

# An empty signing key makes an unsigned lightweight tag.
tag_deploy() {
	if [ -n "$2" ]; then
		git_build -c gpg.format=ssh -c user.signingkey="$2" \
			tag --sign --force --message "Deploy $(git_build rev-parse --short "$1")" deploy "$1"
	else
		git_build tag --force deploy "$1"
	fi
	git_build push --force origin refs/tags/deploy
} >/dev/null 2>&1

site_at() {
	git clone --quiet "$origin" "$siteroot/$1" 2>/dev/null
	git -C "$siteroot/$1" checkout --quiet "$2"
}

run_deploy() {
	PATH="$work/bin:$PATH" STUPID_GIT_DEPLOY_ROOT="$siteroot" STUPID_GIT_DEPLOY_ALLOWED_SIGNERS="$signers" \
		STUPID_GIT_DEPLOY_LOG="$work/deploy.log" STUPID_GIT_DEPLOY_LOCK="$work/deploy.lock" \
		bash "$deploy" "$1" "${2:-}" 2>&1
}

testcase "A valid signed fast-forward deploys"
site_at ok.invalid "$c1"
tag_deploy "$c2" "$work/id"
out=$( run_deploy ok.invalid "$c2" )
exit_code=$?
contains "Good" "$out" "signature verified"
contains "successfully deployed" "$out" "deploy completed"
exits 0 "$exit_code" "exits 0"

testcase "An unsigned deploy tag is refused"
site_at unsigned.invalid "$c1"
tag_deploy "$c2" ""
out=$( run_deploy unsigned.invalid "$c2" )
exit_code=$?
contains "NOT signed by an authorized key" "$out" "unsigned tag refused"
exits 1 "$exit_code" "exits non-zero"

testcase "A tag signed by an unauthorized key is refused"
site_at foreign.invalid "$c1"
tag_deploy "$c2" "$work/foreign"
out=$( run_deploy foreign.invalid "$c2" )
exit_code=$?
contains "NOT signed by an authorized key" "$out" "foreign-key tag refused"
exits 1 "$exit_code" "exits non-zero"

testcase "A non-fast-forward (rollback) is refused"
site_at rollback.invalid "$c2"
tag_deploy "$c1" "$work/id"
out=$( run_deploy rollback.invalid "$c1" )
exit_code=$?
contains "not a fast-forward" "$out" "rollback refused"
exits 1 "$exit_code" "exits non-zero"

testcase "A tag not pointing at the signed commit is refused (SHA pin)"
site_at shapin.invalid "$c1"
tag_deploy "$c2" "$work/id"
# the tag is at c2; passing c1 as the signed commit must be refused
out=$( run_deploy shapin.invalid "$c1" )
exit_code=$?
contains "not the commit you signed" "$out" "SHA-pin mismatch refused"
exits 1 "$exit_code" "exits non-zero"

summary
