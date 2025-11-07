#!/bin/sh

color_out() {
	printf "\e[0;$1m%s%s\e[0m\n" "${PKG_NAME:+$PKG_NAME: }" "$2"
}

success() {
	color_out 32 "$1"
}

info() {
	color_out 36 "$1"
}

err() {
	color_out 31 "$1"
}

warn() {
	color_out 33 "$1"
}

err_die() {
	err "$1"
	exit 1
}

# Prints the string and colors the part after the given length in red
split_fail() {
	printf "%s\e[1;31m%s\e[0m\n" "${2:0:$1}" "${2:$1}"
}

# Prints `[$2] $3` with status colored according to `$1`
status() {
	printf "%s[\e[1;$1m%s\e[0m] %s\n" "${PKG_NAME:+$PKG_NAME: }" "$2" "$3"
}

# Prints `[pass] $1` with green pass (or blue on GitHub)
status_pass() {
	status 32 pass "$1"
}

# Prints `[warn] $1` with yellow warn
status_warn() {
	status 33 warn "$1"
}

# Prints `[fail] $1` with red fail
status_fail() {
	status 31 fail "$1"
}
