#!/usr/bin/env bash
# Run every test-*.sh suite in this directory; exit non-zero if any suite fails.
set -u
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

count=$(find "$dir" -maxdepth 1 -name 'test-*.sh' | wc --lines)
if [ "$count" -eq 0 ]; then
	echo "No test suites (test-*.sh) found in $dir" >&2
	exit 1
fi

exit_code=0
for suite in "$dir"/test-*.sh; do
	if [ -n "${printed:-}" ]; then
		echo
	fi
	printed=1
	echo "# ${suite##*/}"
	bash "$suite" || exit_code=1
done
exit "$exit_code"
