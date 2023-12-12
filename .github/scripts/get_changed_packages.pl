#! /usr/bin/perl

use strict;
use warnings;

my $PACKAGE_DIR = "package";
my $SCAN_DEPTH = 5;

my @PACKAGES_PATH = ();
my @PACKAGES_CHANGED = ();

# Lovely shorthand from https://stackoverflow.com/questions/31724503/most-efficient-way-to-check-if-string-starts-with-needle-in-perl
# Very useless and stupid microptimization that drop execution time of 10ms (maybe?)
sub begins_with
{
    return substr($_[0], 0, length($_[1])) eq $_[1];
}

sub scan_dir
{
	my ($dir, $depth) = @_;

	return if $depth == $SCAN_DEPTH;

	opendir(DIR,"$dir");
	my @files = readdir(DIR);
	closedir(DIR);
	foreach my $file (@files) {
		next if $file eq '.' or $file eq '..' or $file eq 'src';
		my $path = "$dir/$file";
		if (-d $path) {
			scan_dir("$path", $depth + 1);
		}
		# Search only for Makefile and ingore the Makefile in package
		next if not ($file eq "Makefile") or ($dir eq "package");
		push @PACKAGES_PATH, substr $path, 0, -length("Makefile");
	}
}

sub get_changed_packages
{
	my ($CHANGED_FILES) = @_;

	# Traverse all the package directory in search of Makefiles
	scan_dir $PACKAGE_DIR, 0;

	foreach my $file (split ' ', $CHANGED_FILES) {
		next unless begins_with $file, "package/";

		foreach my $package (@PACKAGES_PATH) {
			if (begins_with $file, $package and not grep {$_ eq $package} @PACKAGES_CHANGED) {
				push @PACKAGES_CHANGED, $package;
			}
		}
	}

	foreach my $package (@PACKAGES_CHANGED) {
		# Get the package name from package path
		# Example libfido2 from package/feeds/packages/libfido2
		my ($name) = (split '/', $package)[-1];
		print "$name\n";
	}
}

# Pass a list of changed files and return the list of affected packages
# We manually traverse the package directory in searching for Makefiles.
# We follow the same logic used in scan.mk where the max SCAN_DEPTH is 5
if (@ARGV == 1) {
	get_changed_packages $ARGV[0];
}
else {
	print "Usage: $0 \"changed_files\"\n";
}