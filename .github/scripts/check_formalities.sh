#!/bin/bash

# Based on https://openwrt.org/submitting-patches#submission_guidelines
# Hard limit is arbitrary
MAX_SUBJECT_LEN_HARD=60
MAX_SUBJECT_LEN_SOFT=50
MAX_BODY_LINE_LEN=75

WEBLATE_EMAIL="<hosted@weblate.org>"

RET=0

if [ -f 'workflow_context/.github/scripts/ci_helpers.sh' ]; then
	source workflow_context/.github/scripts/ci_helpers.sh
else
	source .github/scripts/ci_helpers.sh
fi

is_stable_branch() {
	[ "$1" != "main" ] && [ "$1" != "master" ]
}

is_weblate() {
	echo "$1" | grep -iqF "$WEBLATE_EMAIL"
}

check_name() {
	local type="$1"
	local name="$2"

	# Pattern \S\+\s\+\S\+ matches >= 2 names i.e. 3 and more e.g. "John Von
	# Doe" also match
	if echo "$name" | grep -q '\S\+\s\+\S\+'; then
		status_pass "$type name ($name) seems OK"
	# Pattern \S\+ matches single names, typical of nicknames or handles
	elif echo "$name" | grep -q '\S\+'; then
		status_warn "$type name ($name) seems to be a nickname or an alias"
	else
		status_fail "$type name ($name) must be one of:"
		echo "       - real name 'firstname lastname'"
		echo '       - nickname/alias/handle'
		RET=1
	fi
}

check_author_email() {
	local email="$1"

	if echo "$email" | grep -qF "@users.noreply.github.com"; then
		status_fail 'Author email cannot be a GitHub noreply email'
		RET=1
	else
		status_pass 'Author email is not a GitHub noreply email'
	fi
}

check_subject() {
	local subject="$1"
	local author_email="$2"

	# Check subject format
	if echo "$subject" | grep -iq -e '^Translated using Weblate.*' -e '^Added translation using Weblate.*'; then
		status_warn 'Commit subject line exception: authored by Weblate'
	elif echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: [a-z]' -e '^Revert '; then
		status_pass 'Commit subject line format seems OK'
	elif echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: [A-Z]'; then
		status_fail 'First word after prefix in subject should not be capitalized'
		RET=1
	elif echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: '; then
		# Handles cases when there's a prefix but the check for capitalization
		# status_fails (e.g. no word after prefix)
		status_fail "Commit subject line MUST start with '<package name>: ' and be followed by a lower-case word"
		RET=1
	else
		status_fail "Commit subject line MUST start with '<package name>: '"
		RET=1
	fi

	if echo "$subject" | grep -q '\.$'; then
		status_fail 'Commit subject line should not end with a period'
		RET=1
	fi

	if is_weblate "$author_email"; then
		status_warn 'Commit subject line length exception: authored by Weblate'
		return
	fi

	# Check subject length first for hard limit which results in an error and
	# otherwise for a soft limit which results in a warning. Show soft limit in
	# either case.
	if [ ${#subject} -gt "$MAX_SUBJECT_LEN_HARD" ]; then
		status_fail "Commit subject line is longer than $MAX_SUBJECT_LEN_SOFT characters (is ${#subject})"
		split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
		RET=1
	elif [ ${#subject} -gt "$MAX_SUBJECT_LEN_SOFT" ]; then
		status_warn "Commit subject line is longer than $MAX_SUBJECT_LEN_SOFT characters (is ${#subject})"
		split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
	else
		status_pass "Commit subject line is $MAX_SUBJECT_LEN_SOFT characters or less"
	fi
}

check_body() {
	local body="$1"
	local sob="$2"
	local author_email="$3"

	# Check body line lengths
	if ! is_weblate "$author_email"; then
		body_line_too_long=0
		line_num=0
		while IFS= read -r line; do
			line_num=$((line_num + 1))
			if [ ${#line} -gt "$MAX_BODY_LINE_LEN" ]; then
				status_warn "Commit body line $line_num is longer than $MAX_BODY_LINE_LEN characters (is ${#line}):"
				split_fail "$MAX_BODY_LINE_LEN" "$line"
				body_line_too_long=1
			fi
		done <<< "$body"
		if [ "$body_line_too_long" = 0 ]; then
			status_pass "Commit body lines are $MAX_BODY_LINE_LEN characters or less"
		fi
	fi

	if echo "$body" | grep -qF "$sob"; then
		status_pass 'Signed-off-by matches author'
	elif is_weblate "$author_email"; then
		status_warn 'Signed-off-by exception: authored by Weblate'
	else
		status_fail "Signed-off-by is missing or doesn't match author (should be '$sob')"
		RET=1
	fi

	if echo "$body" | grep -qF "@users.noreply.github.com"; then
		status_fail 'Signed-off-by email cannot be a GitHub noreply email'
		RET=1
	else
		status_pass 'Signed-off-by email is not a GitHub noreply email'
	fi

	if echo "$body" | grep -qv "Signed-off-by:"; then
		status_pass 'A commit message exists'
	else
		status_fail 'Commit message is missing. Please describe your changes.'
		RET=1
	fi

	if is_stable_branch "$BRANCH"; then
		if echo "$body" | grep -qF "(cherry picked from commit"; then
			status_pass "Commit is marked as cherry-picked"
		else
			status_warn "Commit on stable branch '$BRANCH' should be cherry-picked"
		fi
	fi
}

main() {
	local author_email
	local author_name
	local body
	local commit
	local committer_name
	local subject

	for commit in $(git rev-list HEAD ^origin/"$BRANCH"); do
		info "=== Checking commit '$commit'"
		if git show --format='%P' -s "$commit" | grep -qF ' '; then
			status_fail 'Pull request should not include merge commits'
			RET=1
		fi

		author_name="$(git show -s --format=%aN "$commit")"
		committer_name="$(git show -s --format=%cN "$commit")"
		check_name "Author" "$author_name"
		check_name "Committer" "$committer_name"

		author_email="$(git show -s --format='<%aE>' "$commit")"
		check_author_email "$author_email"

		subject="$(git show -s --format=%s "$commit")"
		echo
		info 'Checking subject:'
		echo "$subject"
		check_subject "$subject" "$author_email"

		body="$(git show -s --format=%b "$commit")"
		sob="$(git show -s --format='Signed-off-by: %aN <%aE>' "$commit")"
		echo
		info 'Checking body:'
		echo "$body"
		echo
		check_body "$body" "$sob" "$author_email"

		info "=== Done checking commit '$commit'"
		echo
	done

	exit $RET
}

main
