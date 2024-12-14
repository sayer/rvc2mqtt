#!/usr/bin/perl
#
# Copyright (C) 2019 Wandertech LLC
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

$debug = 0;

if ( (@ARGV != 2 || length($ARGV[0]) != 5 || length($ARGV[1]) != 16) ) {
	print "ERR: Insufficient command line data provided.\n";
	usage();
}

my $DGN = $ARGV[0];
my $MESSAGE = $ARGV[1];

print "DGN: $DGN Message: $MESSAGE\n";

$prio = 6;
$dgnhi = substr($DGN, 0, 3);
$dgnlo = substr($DGN, -2);;
$srcAD = '99';

$binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));

	$hexData = $MESSAGE;
	$hexCanId = sprintf("%08X",oct("0b$binCanId"));

  system('cansend can0 '.$hexCanId."#".$hexData);
	print 'cansend can0 '.$hexCanId."#".$hexData."\n"; ## if ($debug);

sub usage {
	print "Usage: \n";
	print "\t$0 <DGN> <MESSAGE>\n";
	print "\n";
	print "\n";
	exit(1);
}
