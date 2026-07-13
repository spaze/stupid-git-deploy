# shellcheck shell=bash
# Shared helpers for the test suites. Nothing here signs, pushes, or ssh's.
# Output is Markdown: ## per test case, - per assertion.

work=$(mktemp --directory)
trap 'rm --recursive --force "$work"' EXIT

# Sandbox git so the suites can't touch the real HOME, signing key, or system
# config, or discover a repo above the work dir.
export HOME=$work/home
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES=$work
mkdir --parents "$HOME"

pass=0
fail=0

testcase() {
	echo
	echo "## $*"
}

contains() {
	local needle=$1 haystack=$2 description=$3
	if printf '%s' "$haystack" | grep --quiet --fixed-strings -- "$needle"; then
		echo "- ok: $description"
		pass=$((pass + 1))
	else
		echo "- FAIL: $description (got: $(printf '%s' "$haystack" | head --lines=2 | tr '\n' '|'))"
		fail=$((fail + 1))
	fi
}

notcontains() {
	local needle=$1 haystack=$2 description=$3
	if printf '%s' "$haystack" | grep --quiet --fixed-strings -- "$needle"; then
		echo "- FAIL: $description (unexpected: $needle)"
		fail=$((fail + 1))
	else
		echo "- ok: $description"
		pass=$((pass + 1))
	fi
}

exits() {
	local want=$1 got=$2 description=$3
	if [ "$got" = "$want" ]; then
		echo "- ok: $description"
		pass=$((pass + 1))
	else
		echo "- FAIL: $description (exit $got, want $want)"
		fail=$((fail + 1))
	fi
}

newrepo() {
	local repo
	repo=$(mktemp --directory "$work/repo.XXXXXX")
	git init --quiet "$repo"
	git -C "$repo" -c user.name=test -c user.email=test@example commit --quiet --allow-empty --message init
	echo "$repo"
}

summary() {
	echo
	echo "\`${0##*/}\`: pass=$pass fail=$fail"
	[ "$fail" -eq 0 ]
}
