#!/bin/sh

# not enabling `errtrace` and `pipefail` since those are bash specific
set -o errexit # failing commands causes script to fail
set -o nounset # undefined variables causes script to fail

mkdir -p /var/lock/
mkdir -p /var/log/

if [ $PKG_MANAGER = "opkg" ]; then
	echo "src/gz packages_ci file:///ci" >> /etc/opkg/distfeeds.conf
	opkg update

elif [ $PKG_MANAGER = "apk" ]; then
	echo "/ci/packages.adb" >> /etc/apk/repositories.d/distfeeds.list
	apk update
fi

CI_HELPERS="${CI_HELPERS:-/scripts/ci_helpers.sh}"

source "$CI_HELPERS"

for PKG in /ci/*.[ai]pk; do
	if [ $PKG_MANAGER = "opkg" ]; then
		tar -xzOf "$PKG" ./control.tar.gz | tar xzf - ./control
		# package name including variant
		PKG_NAME=$(sed -ne 's#^Package: \(.*\)$#\1#p' ./control)
		# package version without release
		PKG_VERSION=$(sed -ne 's#^Version: \(.*\)$#\1#p' ./control)
		PKG_VERSION="${PKG_VERSION%-[!-]*}"
		# package source containing test.sh script
		PKG_SOURCE=$(sed -ne 's#^Source: \(.*\)$#\1#p' ./control)
		PKG_SOURCE="${PKG_SOURCE#/feed/}"

	elif [ $PKG_MANAGER = "apk" ]; then
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
	info "Testing package $PKG_NAME with version $PKG_VERSION from $PKG_SOURCE"

	if ! [ -d "/ci/$PKG_SOURCE" ]; then
		err_die "$PKG_SOURCE is not a directory"
	fi

	PRE_TEST_SCRIPT="/ci/$PKG_SOURCE/pre-test.sh"
	TEST_SCRIPT="/ci/$PKG_SOURCE/test.sh"

	export PKG_NAME PKG_VERSION CI_HELPERS

	if [ -f "$PRE_TEST_SCRIPT" ]; then
		info "Use the package-specific pre-test.sh"
		if sh "$PRE_TEST_SCRIPT" "$PKG_NAME" "$PKG_VERSION"; then
			success "Pre-test successful"
		else
			err_die "Pre-test failed"
		fi

	else
		info "No pre-test.sh script available"
	fi

	if [ $PKG_MANAGER = "opkg" ]; then
		opkg install "$PKG"
	elif [ $PKG_MANAGER = "apk" ]; then
		apk add --allow-untrusted "$PKG"
	fi

	SUCCESS=0
	if [ -f "$TEST_SCRIPT" ]; then
		info "Use the package-specific test.sh"
		if sh "$TEST_SCRIPT" "$PKG_NAME" "$PKG_VERSION"; then
			success "Test successful"
			SUCCESS=1
		else
			err "Test failed"
		fi

	else
		warn "Use a generic test"

		if [ $PKG_MANAGER = "opkg" ]; then
			PKG_FILES=$(opkg files "$PKG_NAME" | grep -E "^(/bin/|/sbin/|/usr/bin/|/usr/libexec/|/usr/sbin/)" || true)
		elif [ $PKG_MANAGER = "apk" ]; then
			PKG_FILES=$(apk info --contents "$PKG_NAME" | grep -E "^(bin/|sbin/|usr/bin/|usr/libexec/|usr/sbin/)" || true)
		fi

		if [ -z "$PKG_FILES" ]; then
			success "No executables found in $PKG_NAME"
			SUCCESS=1
		else
			FOUND_EXEC=0
			for FILE in $PKG_FILES; do
				# apk info --contents does not have a leading /
				if [ $PKG_MANAGER = "apk" ]; then
					FILE="/$FILE"
				fi

				if [ ! -f "$FILE" ] || [ ! -x "$FILE" ]; then
					continue
				fi

				FOUND_EXEC=1
				info "Test executable $FILE and look for $PKG_VERSION"
				for V in --version -version version -v -V --help -help -?; do
					info "Trying $V"
					if "$FILE" "$V" 2>&1 | grep -F "$PKG_VERSION"; then
						SUCCESS=1
						break 2
					fi
				done
			done

			if [ "$FOUND_EXEC" = 1 ]; then
				if [ "$SUCCESS" = 1 ]; then
					success "Test successful"
				else
					err "Test failed"
				fi
			else
				success "No executables found in $PKG_NAME"
				SUCCESS=1
			fi
		fi
	fi

	if [ $PKG_MANAGER = "opkg" ]; then
		opkg remove "$PKG_NAME" \
				--autoremove \
				--force-removal-of-dependent-packages \
				--force-remove \
			|| true
	elif [ $PKG_MANAGER = "apk" ]; then
		apk del --rdepends "$PKG_NAME" || true
	fi

	[ "$SUCCESS" = 1 ] || exit 1
done
