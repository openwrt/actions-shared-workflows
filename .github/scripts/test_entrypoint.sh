#!/bin/sh

# not enabling `errtrace` and `pipefail` since those are bash specific
set -o errexit # failing commands causes script to fail
set -o nounset # undefined variables causes script to fail

mkdir -p /var/lock/
mkdir -p /var/log/

CI_HELPERS="${CI_HELPERS:-/scripts/ci_helpers.sh}"

source "$CI_HELPERS"

generic_tests_enabled() {
	[ "$ENABLE_GENERIC_TESTS" = 'true' ]
}

generic_tests_forced() {
	[ "$FORCE_GENERIC_TESTS" = 'true' ]
}

is_exec() {
	[ -x "$1" ] && echo "$1" | grep -qE '^(/bin/|/sbin/|/usr/bin/|/usr/sbin/|/usr/libexec/)'
}

is_lib() {
	echo "$1" | grep -qE '^(/lib/|/usr/lib/)'
}

is_apk() {
	[ "$PKG_MANAGER" = 'apk' ]
}

is_opkg() {
	[ "$PKG_MANAGER" = 'opkg' ]
}

check_hardcoded_paths() {
	local file="$1"

	if strings "$file" | grep -E '/build_dir/'; then
		status_warn "Binary $file contains a hardcoded build path"
		return 1
	fi

	status_pass "Binary $file does not contain any hardcoded build paths"
	return 0
}

check_exec() {
	local file="$1"
	local has_failure=0

	if [ -x "$file" ]; then
		status_pass "File $file is executable"
	else
		status_fail "File $file in executable path is not executable"
		has_failure=1
	fi

	local found_version=0
	for flag in --version -version version -v -V --help -help -?; do
		if "$file" "$flag" 2>&1 | grep -F "$PKG_VERSION"; then
			status_pass "Found version $PKG_VERSION in $file"
			found_version=1
			break
		fi
	done

	if [ "$found_version" = 0 ]; then
		status_fail "Failed to find version $PKG_VERSION in $file"
		has_failure=1
	fi

	if [ "$has_failure" = 1 ]; then
		return 1
	fi

	return 0
}

check_linked_libs() {
	local file="$1"
	local missing_libs
	missing_libs=$(ldd "$file" 2>/dev/null | grep "not found" || true)
	if [ -n "$missing_libs" ]; then
		status_fail "File $file has missing libraries:"
		echo "$missing_libs"
		return 1
	fi

	status_pass "All linked libraries for $file are present"
	return 0
}

check_lib()	{
	local file="$1"
	local has_failure=0
	local soname
	soname=$(readelf -d "$file" 2>/dev/null | grep 'SONAME' | sed -E 's/.*\[(.*)\].*/\1/')
	if [ -n "$soname" ]; then
		if [ "$(basename "$file")" = "$soname" ]; then
			status_warn "Library $file has the same name as its SONAME '$soname'. The library file should have a more specific version."
		else
			status_pass "Library $file has SONAME '$soname'"
		fi

		# When a library has a SONAME, there should be a symlink with the SONAME
		# pointing to the library file. This is usually in the same directory.
		local lib_dir
		lib_dir=$(dirname "$file")
		if [ ! -L "$lib_dir/$soname" ]; then
			status_fail "Library $file has SONAME '$soname' but no corresponding symlink was found in $lib_dir"
			has_failure=1
		elif [ "$(readlink -f "$lib_dir/$soname")" != "$(readlink -f "$file")" ]; then
			status_fail "Symlink for SONAME '$soname' does not point to $file"
			has_failure=1
		else
			status_pass "SONAME link for $file is correct"
		fi
	else
		status_warn "Library $file doesn't have a SONAME"
	fi

	if [ "$has_failure" = 1 ]; then
		return 1
	fi

	return 0
}

do_generic_tests() {
	local all_files
	if is_opkg; then
		all_files=$(opkg files "$PKG_NAME")
	elif is_apk; then
		all_files=$(apk info --contents "$PKG_NAME" | sed 's#^#/#')
	fi

	local files
	files=$(echo "$all_files" | grep -E '^(/bin/|/sbin/|/usr/bin/|/usr/libexec/|/usr/sbin/|/lib/|/usr/lib/)')

	local has_failure=0
	for file in $files; do
		if [ ! -e "$file" ]; then
			# opkg files can list directories
			continue
		fi

		# Check if it is a symlink and if the target exists
		if [ -L "$file" ]; then
			if [ -e "$(readlink -f "$file")" ]; then
				status_pass "Symlink $file points to an existing file"
			else
				status_fail "Symlink $file points to a non-existent file"
				has_failure=1
			fi

			# Skip symlinks
			continue
		fi

		if is_exec "$file" && ! check_exec "$file"; then
			has_failure=1
		fi

		# Skip non-ELF files
		if ! file "$file" | grep -q "ELF"; then
			continue
		fi

		check_hardcoded_paths "$file"

		if file "$file" | grep 'not stripped'; then
			status_warn "Binary $file is not stripped"
		else
			status_pass "Binary $file is stripped"
		fi

		if ! check_linked_libs "$file"; then
			has_failure=1
		fi

		if is_lib "$file" && ! check_lib "$file"; then
			has_failure=1
		fi
	done

	if [ "$has_failure" = 1 ]; then
		err "Generic tests failed"
		return 1
	fi

	success "Generic tests passed"
	return 0
}

if is_opkg; then
	echo "src/gz packages_ci file:///ci" >> /etc/opkg/distfeeds.conf
	# Disable checking signature for all opkg feeds, since it doesn't look like
	# it's possible to do it for the local feed only, which has signing removed.
	# This fixes running CI tests.
	sed -i '/check_signature/d' /etc/opkg.conf
	opkg update
	opkg install binutils file
elif is_apk; then
	echo "/ci/packages.adb" >> /etc/apk/repositories.d/distfeeds.list
	apk update
	apk add binutils file
fi

if generic_tests_enabled && generic_tests_forced; then
	warn 'Generic tests are enabled and forced'
elif generic_tests_enabled; then
	warn 'Generic tests are enabled'
else
	warn 'Generic tests are disabled'
fi

for PKG in /ci/*.[ai]pk; do
	if is_opkg; then
		tar -xzOf "$PKG" ./control.tar.gz | tar xzf - ./control
		# package name including variant
		PKG_NAME=$(sed -ne 's#^Package: \(.*\)$#\1#p' ./control)
		# package version without release
		PKG_VERSION=$(sed -ne 's#^Version: \(.*\)$#\1#p' ./control)
		PKG_VERSION="${PKG_VERSION%-[!-]*}"
		# package source containing test.sh script
		PKG_SOURCE=$(sed -ne 's#^Source: \(.*\)$#\1#p' ./control)
		PKG_SOURCE="${PKG_SOURCE#/feed/}"
	elif is_apk; then
		# package name including variant
		PKG_NAME=$(apk adbdump --format json "$PKG" | jsonfilter -e '@["info"]["name"]')
		# package version without release
		PKG_VERSION=$(apk adbdump --format json "$PKG" | jsonfilter -e '@["info"]["version"]')
		PKG_VERSION="${PKG_VERSION%-[!-]*}"
		# package source containing test.sh script
		PKG_SOURCE=$(apk adbdump --format json "$PKG" | jsonfilter -e '@["info"]["origin"]')
		PKG_SOURCE="${PKG_SOURCE#/feed/}"
	fi

	echo
	info "Testing package version $PKG_VERSION from $PKG_SOURCE"

	if ! [ -d "/ci/$PKG_SOURCE" ]; then
		err_die "$PKG_SOURCE is not a directory"
	fi

	PRE_TEST_SCRIPT="/ci/$PKG_SOURCE/pre-test.sh"
	TEST_SCRIPT="/ci/$PKG_SOURCE/test.sh"

	export PKG_NAME PKG_VERSION CI_HELPERS

	if [ -f "$PRE_TEST_SCRIPT" ]; then
		info 'Use the package-specific pre-test.sh'
		if sh "$PRE_TEST_SCRIPT" "$PKG_NAME" "$PKG_VERSION"; then
			success 'Pre-test passed'
		else
			err_die 'Pre-test failed'
		fi
	else
		info 'No pre-test.sh script available'
	fi

	if is_opkg; then
		opkg install "$PKG"
	elif is_apk; then
		apk add --allow-untrusted "$PKG"
	fi

	SUCCESS=0

	if generic_tests_enabled && ( generic_tests_forced || [ ! -f "$TEST_SCRIPT" ] ); then
		warn 'Use generic tests'
		if do_generic_tests; then
			SUCCESS=1
		fi
	fi

	if [ -f "$TEST_SCRIPT" ]; then
		info 'Use the package-specific test.sh'
		if sh "$TEST_SCRIPT" "$PKG_NAME" "$PKG_VERSION"; then
			success 'Test passed'
			SUCCESS=1
		else
			err 'Test failed'
		fi
	fi

	if is_opkg; then
		opkg remove "$PKG_NAME" \
				--autoremove \
				--force-removal-of-dependent-packages \
				--force-remove \
			|| true
	elif is_apk; then
		apk del --rdepends "$PKG_NAME" || true
	fi

	[ "$SUCCESS" = 1 ] || exit 1
done
