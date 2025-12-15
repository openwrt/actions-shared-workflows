#!/bin/bash

# Based on https://openwrt.org/submitting-patches#submission_guidelines
# Hard limit is arbitrary
MAX_SUBJECT_LEN_HARD=60
MAX_SUBJECT_LEN_SOFT=50
MAX_BODY_LINE_LEN=75

DEPENDABOT_EMAIL="dependabot[bot]@users.noreply.github.com"
GITHUB_NOREPLY_EMAIL='@users.noreply.github.com'
WEBLATE_EMAIL='<hosted@weblate.org>'

EMOJI_WARN=':large_orange_diamond:'
EMOJI_FAIL=':x:'

RET=0

REPO_PATH=${1:+-C "$1"}
# shellcheck disable=SC2206
REPO_PATH=($REPO_PATH)

if [ -f 'workflow_context/.github/scripts/ci_helpers.sh' ]; then
	source workflow_context/.github/scripts/ci_helpers.sh
else
	source .github/scripts/ci_helpers.sh
fi

# Use these global vars to improve header creation readability
COMMIT=""
HEADER_SET=0

output() {
	[ -f "$GITHUB_OUTPUT" ] || return

	echo "$1" >> "$GITHUB_OUTPUT"
}

output_header() {
	[ "$HEADER_SET" = 0 ] || return

	[ -f "$GITHUB_OUTPUT" ] || return

	cat >> "$GITHUB_OUTPUT" <<-HEADER

	### Commit $COMMIT

	HEADER

	HEADER_SET=1
}

output_warn() {
	output_header
	output "- $EMOJI_WARN $1"
	status_warn "$1"
}

output_fail_raw() {
	output_header
	output "$1"
	status_fail "$1"
}

output_fail() {
	output_header
	output "- $EMOJI_FAIL $1"
	status_fail "$1"
}

is_stable_branch() {
	[ "$1" != "main" ] && [ "$1" != "master" ]
}

is_dependabot() {
	echo "$1" | grep -iqF "$DEPENDABOT_EMAIL"
}

is_weblate() {
	echo "$1" | grep -iqF "$WEBLATE_EMAIL"
}

exclude_dependabot() {
	[ "$EXCLUDE_DEPENDABOT" = 'true' ]
}

exclude_weblate() {
	[ "$EXCLUDE_WEBLATE" = 'true' ]
}

check_name() {
	local type="$1"
	local name="$2"
	local email="$3"

	if exclude_dependabot && is_dependabot "$email"; then
		status_warn "$type email exception: authored by dependabot"
	elif exclude_weblate && is_weblate "$email"; then
		status_warn "$type email exception: authored by Weblate"
	# Pattern \S\+\s\+\S\+ matches >= 2 names i.e. 3 and more e.g. "John Von
	# Doe" also match
	elif echo "$name" | grep -q '\S\+\s\+\S\+'; then
		status_pass "$type name ($name) seems OK"
	# Pattern \S\+ matches single names, typical of nicknames or handles
	elif echo "$name" | grep -q '\S\+'; then
		output_warn "$type name ($name) seems to be a nickname or an alias"
	else
		output_fail "$type name ($name) must be one of:"
		output_fail_raw "    - real name 'firstname lastname'"
		output_fail_raw '    - nickname/alias/handle'
		RET=1
	fi
}

check_email() {
	local type="$1"
	local email="$2"

	if exclude_dependabot && is_dependabot "$email"; then
		status_warn "$type email exception: authored by dependabot"
	elif exclude_weblate && is_weblate "$email"; then
		status_warn "$type email exception: authored by Weblate"
	elif echo "$email" | grep -qF "$GITHUB_NOREPLY_EMAIL"; then
		output_fail "$type email cannot be a GitHub noreply email"
		RET=1
	else
		status_pass "$type email is not a GitHub noreply email"
	fi
}

check_subject() {
	local subject="$1"
	local author_email="$2"

	# Check subject format
	if exclude_dependabot && is_dependabot "$author_email"; then
		status_warn 'Commit subject line exception: authored by dependabot'
	elif exclude_weblate && is_weblate "$author_email"; then
		status_warn 'Commit subject line exception: authored by Weblate'
	elif echo "$subject" | grep -qE -e '^([0-9A-Za-z,+/._-]+: )+[a-z]' -e '^Revert '; then
		status_pass 'Commit subject line format seems OK'
	elif echo "$subject" | grep -qE -e '^([0-9A-Za-z,+/._-]+: )+[A-Z]'; then
		output_fail 'First word after prefix in subject should not be capitalized'
		RET=1
	elif echo "$subject" | grep -qE -e '^([0-9A-Za-z,+/._-]+: )+'; then
		# Handles cases when there's a prefix but the check for capitalization
		# fails (e.g. no word after prefix)
		output_fail 'Commit subject line MUST start with `<package name>: ` and be followed by a lower-case word'
		RET=1
	else
		output_fail 'Commit subject line MUST start with `<package name>: `'
		RET=1
	fi

	if echo "$subject" | grep -q '\.$'; then
		output_fail 'Commit subject line should not end with a period'
		RET=1
	fi

	# Don't append to the workflow output, since these are more of internal
	# warnings.
	if exclude_dependabot && is_dependabot "$author_email"; then
		status_warn 'Commit subject line length exception: authored by dependabot'
		return
	elif exclude_weblate && is_weblate "$author_email"; then
		status_warn 'Commit subject line length exception: authored by Weblate'
		return
	fi

	# Check subject length first for hard limit which results in an error and
	# otherwise for a soft limit which results in a warning. Show soft limit in
	# either case.
	local msg="Commit subject length: recommended max $MAX_SUBJECT_LEN_SOFT, required max $MAX_SUBJECT_LEN_HARD characters"
	if [ ${#subject} -gt "$MAX_SUBJECT_LEN_HARD" ]; then
		output_fail "$msg"
		split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
		RET=1
	elif [ ${#subject} -gt "$MAX_SUBJECT_LEN_SOFT" ]; then
		output_warn "$msg"
		split_fail "$MAX_SUBJECT_LEN_SOFT" "$subject"
	else
		status_pass "$msg"
	fi
}

check_body() {
	local body="$1"
	local sob="$2"
	local author_email="$3"

	# Check body line lengths
	if ! { exclude_weblate && is_weblate "$author_email"; } && ! { exclude_dependabot && is_dependabot "$author_email"; }; then
		body_line_too_long=0
		line_num=0
		while IFS= read -r line; do
			line_num=$((line_num + 1))
			if [ ${#line} -gt "$MAX_BODY_LINE_LEN" ]; then
				output_warn "Commit body line $line_num is longer than $MAX_BODY_LINE_LEN characters (is ${#line}):"
				output "    $line"
				split_fail "$MAX_BODY_LINE_LEN" "$line"
				body_line_too_long=1
			fi
		done <<< "$body"
		if [ "$body_line_too_long" = 0 ]; then
			status_pass "Commit body lines are $MAX_BODY_LINE_LEN characters or less"
		fi
	else
		if exclude_dependabot && is_dependabot "$author_email"; then
			status_warn 'Commit body line length exception: authored by dependabot'
		elif exclude_weblate && is_weblate "$author_email"; then
			status_warn 'Commit body line length exception: authored by Weblate'
		fi
	fi

	if echo "$body" | grep -qF "$sob"; then
		status_pass '`Signed-off-by` matches author'

	# Don't append to the workflow output, since these are more of internal
	# warnings.
	elif exclude_dependabot && is_dependabot "$author_email"; then
		status_warn '`Signed-off-by` exception: authored by dependabot'
	elif exclude_weblate && is_weblate "$author_email"; then
		status_warn '`Signed-off-by` exception: authored by Weblate'

	else
		output_fail "\`Signed-off-by\` is missing or doesn't match author (should be \`$sob\`)"
		RET=1
	fi

	if ! ( exclude_dependabot && is_dependabot "$author_email" ) && ! ( exclude_weblate && is_weblate "$author_email" ); then
		if echo "$body" | grep -qF "$GITHUB_NOREPLY_EMAIL"; then
			output_fail '`Signed-off-by` email cannot be a GitHub noreply email'
			RET=1
		else
			status_pass '`Signed-off-by` email is not a GitHub noreply email'
		fi
	fi

	if echo "$body" | grep -v "Signed-off-by:" | grep -qv '^[[:space:]]*$'; then
		status_pass 'A commit message exists'
	else
		output_fail 'Commit message is missing. Please describe your changes.'
		RET=1
	fi

	if is_stable_branch "$BRANCH"; then
		if echo "$body" | grep -qF "(cherry picked from commit"; then
			status_pass "Commit is marked as cherry-picked"
		else
			output_warn "Commit tog stable branch \`$BRANCH\` should be cherry-picked"
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

	# Initialize GitHub actions output
	output 'content<<EOF'

	cat <<-EOF
	Something broken? Consider providing feedback:
	https://github.com/openwrt/actions-shared-workflows/issues

	EOF

	if exclude_dependabot; then
		warn 'dependabot exceptions are enabled'
	else
		echo 'dependabot exceptions are disabled'
	fi

	if exclude_weblate; then
		warn 'Weblate exceptions are enabled'
	else
		echo 'Weblate exceptions are disabled'
	fi
	echo

	for commit in $(git "${REPO_PATH[@]}" rev-list HEAD ^origin/"$BRANCH"); do
		HEADER_SET=0
		COMMIT="$commit"

		info "=== Checking commit '$commit'"
		if git "${REPO_PATH[@]}" show --format='%P' -s "$commit" | grep -qF ' '; then
			output_fail 'Pull request should not include merge commits'
			RET=1
		fi

		author_name="$(git "${REPO_PATH[@]}" show -s --format=%aN "$commit")"
		committer_name="$(git "${REPO_PATH[@]}" show -s --format=%cN "$commit")"
		author_email="$(git "${REPO_PATH[@]}" show -s --format='<%aE>' "$commit")"
		committer_email="$(git "${REPO_PATH[@]}" show -s --format='<%cE>' "$commit")"
		check_name 'Author' "$author_name" "$author_email"
		check_email 'Author' "$author_email"
		check_name 'Committer' "$committer_name" "$committer_email"
		check_email 'Committer' "$committer_email"

		subject="$(git "${REPO_PATH[@]}" show -s --format=%s "$commit")"
		echo
		info 'Checking subject:'
		echo "$subject"
		check_subject "$subject" "$author_email"

		body="$(git "${REPO_PATH[@]}" show -s --format=%b "$commit")"
		sob="$(git "${REPO_PATH[@]}" show -s --format='Signed-off-by: %aN <%aE>' "$commit")"
		echo
		info 'Checking body:'
		echo "$body"
		echo
		check_body "$body" "$sob" "$author_email"

		info "=== Done checking commit '$commit'"
		echo
	done

	output 'EOF'

	exit $RET
}

main
