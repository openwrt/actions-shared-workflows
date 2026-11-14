#!/bin/bash
# Runs inside ghcr.io/openwrt/sdk:<arch>-<branch> as the buildbot user.
# /src is the checkout of the project, /artifacts receives apk/, logs/
# and sizes.txt.
#
# PACKAGE   source package of the project in the feed, e.g. odhcpd
# PACKAGES  binary packages to build, defaults to $PACKAGE
# FEED      feed providing the source package, defaults to base

set -e

[ -n "$PACKAGE" ] || {
	echo "::error::PACKAGE is not set"
	exit 1
}

PACKAGES="${PACKAGES:-$PACKAGE}"
FEED="${FEED:-base}"
JOBS="${JOBS:-$(nproc)}"

group() {
	echo "::group::$1"
}

endgroup() {
	echo "::endgroup::"
}

group "setup.sh"
[ ! -f setup.sh ] || bash setup.sh
endgroup

git config --global --add safe.directory '*'

sed -n \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	-e '/^src-git.* base /p' \
	-e "/^src-git.* $FEED /p" \
	feeds.conf.default | sort -u > feeds.conf

group "feeds"
cat feeds.conf
./scripts/feeds update -a
./scripts/feeds install "$PACKAGE"
endgroup

makefile="$(readlink -f "package/feeds/$FEED/$PACKAGE/Makefile")"
[ -f "$makefile" ] || {
	echo "::error::$PACKAGE is not a source package of the $FEED feed"
	exit 1
}

mkdir -p git-src
ln -sfn /src "git-src/$PACKAGE"

sed -i \
	-e "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=$(git -C /src log -1 --format=%cd --date=format:%Y-%m-%d)/" \
	-e "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$(git -C /src rev-parse HEAD)/" \
	-e '/^PKG_MIRROR_HASH:=/d' \
	"$makefile"

for pkg in $PACKAGES; do
	echo "CONFIG_PACKAGE_$pkg=m" >> .config
done

group "make defconfig"
make defconfig </dev/null
endgroup

for pkg in $PACKAGES; do
	grep -qx "CONFIG_PACKAGE_$pkg=[ym]" .config || {
		echo "::error::$pkg cannot be selected for $(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' .config)"
		exit 1
	}
done

RET=0
make -j"$JOBS" BUILD_LOG=1 IGNORE_ERRORS=n "package/$PACKAGE/compile" </dev/null || RET=$?

if [ "$RET" -ne 0 ]; then
	for log in $(find logs -path "*/$PACKAGE/*" -name '*.txt' 2>/dev/null); do
		echo "::group::$log"
		tail -n 200 "$log"
		echo "::endgroup::"
	done
fi

mkdir -p /artifacts/apk
[ ! -d logs ] || cp -a logs /artifacts/
[ "$RET" -eq 0 ] || exit "$RET"

find bin/packages -name '*.apk' -exec cp {} /artifacts/apk/ \;
find bin/targets -path '*/packages/*.apk' ! -name 'kmod-*' ! -name 'kernel-*' \
	-exec cp {} /artifacts/apk/ \;

for pkg in $PACKAGES; do
	apk="$(find /artifacts/apk -name "$pkg-[0-9]*.apk")"
	[ -n "$apk" ] || {
		echo "::error::$pkg was not built"
		exit 1
	}
	echo "$pkg $(stat -c %s "$apk")"
done > /artifacts/sizes.txt
