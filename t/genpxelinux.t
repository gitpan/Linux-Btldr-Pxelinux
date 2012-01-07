#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 46;
use File::Slurp;
use File::Temp qw(tempdir);
use FindBin;
use Test::Output qw(combined_from);

my $debug = 0;

my $tmp = tempdir(CLEANUP => ! $debug);

diag "tmp = $tmp" if $debug;

my $config = join('', <DATA>);

mkdir "$tmp/tftpboot";
my $dir = "$tmp/tftpboot/pxelinux.cfg";
mkdir $dir;
mkdir "$tmp/tftpboot/menus";

write_file("$dir/template.gen", $config);
write_file("$dir/config.gen", <<'END_CONFIG_GEN');
#SET nfs1	172.20.1.10:/nfs
#SET nfs2	172.20.1.11:/nfs
END_CONFIG_GEN
write_file("$tmp/tftpboot/chain.c32", "");
mkdir "$tmp/tftpboot/linux";
write_file("$tmp/tftpboot/linux/staid-vmlinuz-2.6.12-3", "");
write_file("$tmp/tftpboot/memdisk", "");

@ARGV = (
	"--tftpboot=$tmp/tftpboot",
	"--template=$dir/template.gen",
	"--debug=$debug",
);


my $r;
my $output = combined_from {
	$r = do "$FindBin::Bin/../genpxelinux.pl";
};
is($@, '', "ran without error");
is($r, 'completed', "evaluation confirmation");
like($output, qr/\A\z/, "no output");


for my $m (qw(
	bootmsg.DISPLAY.default
	bootmsg.DISPLAY.dell1
	bootmsg.DISPLAY.dell2
	bootmsg.F1.default
	bootmsg.F2.default
	bootmsg.F2.dell1
	bootmsg.F2.dell2
	bootmsg.F3.default
	bootmsg.F4.default
	bootmsg.F6.default
)) {
	ok(-e "$tmp/tftpboot/menus/$m", "menu $m generated");
}
for my $m (qw(
	bootmsg.F1.dell1
	bootmsg.F1.dell2
	bootmsg.F1.nfs1
	bootmsg.F1.nfs2
	bootmsg.F3.dell1
	bootmsg.F3.dell2
	bootmsg.F3.nfs1
	bootmsg.F3.nfs2
	bootmsg.F4.dell1
	bootmsg.F4.dell2
	bootmsg.F4.nfs1
	bootmsg.F4.nfs2
	bootmsg.F6.dell1
	bootmsg.F6.dell2
	bootmsg.F6.nfs1
	bootmsg.F6.nfs2
)) {
	ok(! -e "$tmp/tftpboot/menus/$m", "no menu $m generated");
}

for my $m (qw(
	default
	dell1
	dell2
	01-00-06-5b-04-cb-4d
	01-00-06-5b-3a-31-d1
)) {
	ok(-e "$dir/$m", "config file $m generated");
}
for my $m (qw(
	nfs1
	nfs2
)) {
	ok(! -e "$dir/$m", "no config file $m generated");
}


my $f1default = read_file("$tmp/tftpboot/menus/bootmsg.F1.default");
like($f1default, qr/localboot 0x80/, "menu includes localboot");

my $dell2link = readlink("$dir/01-00-06-5b-04-cb-4d");
is($dell2link, "dell2", "link to dell config");

my $default = read_file("$dir/default");

my %stanzas = parse_config($default);

sub parse_config
{
	my ($config) = @_;
	my %stanzas;
	my $key;
	for (split(/\n/, $config)) {
		next if /^#/;
		if (/^(\S+)/) {
			$key = $_;
			$key =~ s/\s+/ /g;
			fail("duplicate key $key") if $stanzas{$key};
		}
		$stanzas{$key} .= $_ . "\n";
	}
	return %stanzas;
}

ok($stanzas{"F6 menus/bootmsg.F6.default"}, "F6");
like($stanzas{"LABEL hd3a"}, qr{\ALABEL hd3a\n\s+KERNEL\s+chain.c32\n\s+APPEND\s+hd3 1$}m, "hda3 clause");
like($stanzas{"LABEL nfs2"}, qr{root=/dev/nfs nfsroot=172.20.1.11:/nfs console=tty0}, "variable interpolation");
ok($stanzas{"DEFAULT disk"}, "DEFAULT disk");
unlike($stanzas{"LABEL nfs2"}, qr{mem=3050}, "extra vars unset");
ok($stanzas{"SERIAL 0 9600 0x003"}, "interpolation before definition");

my %dell2 = parse_config(scalar(read_file("$dir/dell2")));

ok($dell2{"DEFAULT nfs1"}, "dell2 default");
like($dell2{"LABEL nfs2"}, qr{mem=3050}, "extra vars set");

# diag read_file("$dir/dell2");
# diag $default;

diag $f1default if $debug;
diag "tmp = $tmp" if $debug;
__DATA__

SERIAL 0 $(9600) 0x003
DEFAULT disk
TIMEOUT 200
PROMPT 1

#SET 9600 9600

#SYSTEM	01-00-06-5b-3a-31-d1 dell1
#FOR dell1	#SET memlimit mem=3050m
#FOR dell1	DEFAULT nfs2

#SYSTEM 01-00-06-5b-04-cb-4d dell2
#FOR dell2	#SET memlimit mem=3050m
#FOR dell2	DEFAULT nfs1

# must set $(nfs1) and $(nfs2)
#INCLUDE config.gen

#MENU DISPLAY
<Ctrl-F><digit> for menus:
1-disk booting  3-Disk tools      5-tbd         7-dell stuff    9-tbd
2-Linux         4-hardware testng 6-misc        8-tbd           0-this menu
DEFAULT is $(directive_DEFAULT)

#END

############################################################################
#MENU F1
		Disk Booting
#END
############################################################################

LABEL disk
	#ITEM		localboot
	LOCALBOOT 0
LABEL lb80
	#ITEM		"localboot 0x80"
	LOCALBOOT 0x80
LABEL lb81
	#ITEM		"localboot 0x81"
	LOCALBOOT 0x81
LABEL hd0mbr
	#ITEM		<hd[0123]mbr>     mbr boot off disk 0,1,2,3
	KERNEL	chain.c32
	APPEND	hd0
LABEL hd0a
	#ITEM		<hd[0123][abcd]>  boot off disk 0,1,2,3 partition a-d (1-4)
	KERNEL	chain.c32
	APPEND	hd0 1
LABEL hd0b
	KERNEL	chain.c32
	APPEND	hd0 2
LABEL hd0c
	KERNEL	chain.c32
	APPEND	hd0 3
LABEL hd0d
	KERNEL	chain.c32
	APPEND	hd0 4

LABEL hj1mbr
	KERNEL	chain.c32
	APPEND	hd1
LABEL hd1a
	KERNEL	chain.c32
	APPEND	hd1 1
LABEL hd1b
	KERNEL	chain.c32
	APPEND	hd1 2
LABEL hd1c
	KERNEL	chain.c32
	APPEND	hd1 3
LABEL hd1d
	KERNEL	chain.c32
	APPEND	hd1 4

LABEL hd2mbr
	KERNEL	chain.c32
	APPEND	hd2
LABEL hd2a
	KERNEL	chain.c32
	APPEND	hd2 1
LABEL hd2b
	KERNEL	chain.c32
	APPEND	hd2 2
LABEL hd2c
	KERNEL	chain.c32
	APPEND	hd2 3
LABEL hd2d
	KERNEL	chain.c32
	APPEND	hd2 4

LABEL hd3mbr
	KERNEL	chain.c32
	APPEND	hd3
LABEL hd3a
	KERNEL	chain.c32
	APPEND	hd3 1
LABEL hd3b
	KERNEL	chain.c32
	APPEND	hd3 2
LABEL hd3c
	KERNEL	chain.c32
	APPEND	hd3 3
LABEL hd3d
	KERNEL	chain.c32
	APPEND	hd3 4


############################################################################
#MENU F2
		Linux Recovery Mode
#END
############################################################################

LABEL nfs1
	#ITEM		Diskless, $(nfs1)
	KERNEL linux/staid-vmlinuz-2.6.12-3
	APPEND root=/dev/nfs nfsroot=$(nfs1) console=tty0 console=ttyS0,$(9600) panic=30 no1394 $(memlimit)
	IPAPPEND 1

LABEL nfs2
	#ITEM		Diskless, $(nfs2)
	KERNEL linux/staid-vmlinuz-2.6.12-3
	APPEND root=/dev/nfs nfsroot=$(nfs2) console=tty0 console=ttyS0,$(9600) panic=30 no1394 $(memlimit)
	IPAPPEND 1

############################################################################
#MENU F3
		Disk Tools
#END
############################################################################

LABEL ibm1
	#ITEM F3	IBM's Drive Fitness Test
	KERNEL memdisk
	APPEND initrd=tools/dft32_v405_b00_install.img
LABEL ibm2
	#ITEM F3	IBM's Drive Feature Tool
	KERNEL memdisk
	APPEND initrd=tools/ftool_198_install.img
LABEL maxtor
	#ITEM F3	Maxtor's MaxBlast
	KERNEL memdisk
	APPEND initrd=tools/maxblast.img
LABEL seagate
	#ITEM F3	Seagate Seatools
	KERNEL memdisk
	APPEND initrd=tools/seatools-1.09.img
LABEL killdisk
	#ITEM F3	killdisk from the ultimate boot cdrom
	KERNEL memdisk
	APPEND initrd=tools/killdisk.img

############################################################################
#MENU F4
		Hardware Testing
#END
############################################################################

LABEL memtest86+
	#ITEM F4	MemTest86+, http://www.memtest.org
	KERNEL memdisk
	APPEND initrd=tools/memtest86+-1.70.img
LABEL memtest+
	KERNEL memdisk
	APPEND initrd=tools/memtest86+-1.70.img
LABEL memtest
	#ITEM F4	memtest86
	KERNEL memdisk
	APPEND initrd=tools/memtest86.img
LABEL memtest86
	KERNEL memdisk
	APPEND initrd=tools/memtest86.img
LABEL sniff
	#ITEM F4	PCI Sniffer, http://www.miray.de/products/sat.pcisniffer.html
	KERNEL memdisk
	APPEND initrd=tools/pcisniffer.img

############################################################################
#MENU F6
		Miscellaneous Stuff
#END
############################################################################

LABEL ntpasswd
	#ITEM F6	NT Registry & Password reset tool
	# http://home.eunet.no/~pnordahl/ntpasswd/bootdisk.html
	KERNEL memdisk
	APPEND initrd=tools/bd050303.bin

