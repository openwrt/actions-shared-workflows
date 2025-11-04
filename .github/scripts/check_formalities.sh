#!/bin/bash

source workflow_context/.github/scripts/ci_helpers.sh

RET=0
for commit in $(git rev-list HEAD ^origin/"$BRANCH"); do
	info "=== Checking commit '$commit'"
	if git show --format='%P' -s "$commit" | grep -qF ' '; then
		err "Pull request should not include merge commits"
		RET=1
	fi

	author_name="$(git show -s --format=%aN "$commit")"
	# Pattern \S\+\s\+\S\+ matches >= 2 names i.e. 3 and more e.g. "John Von
	# Doe" also match
	if echo "$author_name" | grep -q '\S\+\s\+\S\+'; then
		success "Author name ($author_name) seems OK"
	# Pattern \S\+ matches single names, typical of nicknames or handles
	elif echo "$author_name" | grep -q '\S\+'; then
		warn "Author name ($author_name) seems to be a nickname or an alias"
	else
		err "Author name ($author_name) must be one of:"
		err "- real name 'firstname lastname' OR"
		err '- nickname/alias/handle'
		RET=1
	fi

	author_email="$(git show -s --format='%aE' "$commit")"
	if echo "$author_email" | grep -qF "@users.noreply.github.com"; then
		err "Author email cannot be a GitHub noreply email"
		RET=1
	else
		success "Author email is not a GitHub noreply email"
	fi

	committer_name="$(git show -s --format=%cN "$commit")"
	# Pattern \S\+\s\+\S\+ matches >= 2 names i.e. 3 and more e.g. "John Von
	# Doe" also match
	if echo "$committer_name" | grep -q '\S\+\s\+\S\+'; then
		success "Committer name ($committer_name) seems OK"
	# Pattern \S\+ matches single names, typical of nicknames or handles
	elif echo "$committer_name" | grep -q '\S\+'; then
		warn "Committer name ($committer_name) seems to be a nickname or an alias"
	else
		err "Committer name ($committer_name) must be one of:"
		err "- real name 'firstname lastname' OR"
		err '- nickname/alias/handle'
		RET=1
	fi

	subject="$(git show -s --format=%s "$commit")"
	if echo "$subject" | grep -q -e '^[0-9A-Za-z,+/_-]\+: ' -e '^Revert '; then
		success "Commit subject line seems OK ($subject)"
	elif echo "$subject" | grep -iq '^Translated using Weblate.*'; then
		warn "Weblate commit subject line exception: $subject"
	elif echo "$subject" | grep -iq '^Added translation using Weblate.*'; then
		warn "Weblate commit subject line exception: $subject"
	else
		err "Commit subject line MUST start with '<package name>: ' ($subject)"
		RET=1
	fi

	body="$(git show -s --format=%b "$commit")"
	sob="$(git show -s --format='Signed-off-by: %aN <%aE>' "$commit")"
	if echo "$body" | grep -qF "$sob"; then
		success "Signed-off-by matches author"
	elif echo "$author_email" | grep -iqF "<hosted@weblate.org>"; then
		warn "Signed-off-by exception: authored by Weblate"
	else
		err "Signed-off-by is missing or doesn't match author (should be '$sob')"
		RET=1
	fi

	if echo "$body" | grep -qF "@users.noreply.github.com"; then
		err "Signed-off-by email cannot be a GitHub noreply email"
		RET=1
	else
		success "Signed-off-by email is not a GitHub noreply email"
	fi

	if echo "$body" | grep -v "Signed-off-by:"; then
		success "A commit message exists"
	else
		err "Commit message is missing. Please describe your changes."
		RET=1
	fi
done

exit $RET
