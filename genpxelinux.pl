#!/usr/bin/perl

package Linux::Bootloader::genpxelinux;

our $VERSION = 0.23;

my $tftpboot = "/tftpboot";
my $cfg = "pxelinux.cfg";
my $template;
my $menufmt = "%15s %s\n";
my $menudir = "menus";
my $max_levels = 100; # variable substitution recursion
my $debug = 0;

use strict;
use warnings;
use File::Slurp;
use Getopt::Long;
use Text::Tabs;

my $directivesrx = qr/(?:SERIAL|DEFAULT|DISPLAY|TIMEOUT|PROMPT|F[1-9]|INCLUDE|APPEND|IPAPPEND|IMPLICIT|ALLOWOPTIONS|TOTALTIMEOUT|ONTIMEOUT|ONERROR|CONSOLE|FONT|KBDMAP|SAY|NOESCAPE)/;
my $menurx	 = qr/(?:-|DISPLAY|F[1-9])/;
my $hexdigitrx	 = qr/[a-f0-9]/i;
my $hexrx	 = qr/$hexdigitrx$hexdigitrx/;

my $body;			# text of the new config file (before post-processing)
my %systems;			# system name -> [ address(es) ]
my %sysaddrs;			# address -> name
my %system_originals;		# original system anme (before mangling for pxelinux)

my %menus;			# DISPLAY, F1, F2, etc. -> text
my %menu_overrides;		# per system %menus
my $lastmenu = 'DISPLAY';	# the last #MENU directive seen

my %directives;			# SERAIL, DEFAULT, PROMT etc
my %directive_overrides;	# per system %directives

my %vars;			# #SET variables 
my %var_overrides;		# per system %vars

my %labels;			# Which labels have been seen

$systems{default} = [ 'default' ];
$system_originals{default} = [ ];
$vars{'$'} = '$';

Getopt::Long::Configure("auto_version");
GetOptions(
	'tftpboot=s'	=> \$tftpboot,
	'template=s'	=> \$template,
	'menufmt=s'	=> \$menufmt,
	'menudir=s'	=> \$menudir,
	'cfg=s'		=> \$cfg,
	'debug=s'	=> \$debug,
) or die usage();
die usage() if @ARGV;

$template = "$tftpboot/$cfg/template.gen" unless defined $template;

readconfig($template);

die "must define default menu" unless $menu_overrides{default}{DISPLAY} || $menus{DISPLAY};

for my $sys (keys %systems) {

	# variables & direcitves

	my %repl = %vars;
	@repl{keys %{$var_overrides{$sys}}} = values %{$var_overrides{$sys}};
	for my $d (sort keys %directives) {
		next if exists $directive_overrides{$sys}{$d};
		$repl{"directive_$d"} = $directives{$d};
	}
	for my $d (sort keys %{$directive_overrides{$sys}}) {
		$repl{"directive_$d"} = $directive_overrides{$sys}{$d};
	}

	# write menu files

	for my $menu (qw(DISPLAY F1 F2 F3 F4 F5 F6 F7 F8 F9)) {
		my $contents = $menu_overrides{$sys}{$menu} || $menus{$menu} || '';

		if ($sys eq 'default' || $menu_overrides{$sys}{$menu} || $contents =~ /\$\(.*?\)/) {
			my $contents = $menu_overrides{$sys}{$menu} || $menus{$menu};
			next unless $contents;
			my $new = '';
			var_sub(\$contents, \$new, \%repl, 0, "menu $menu for $sys");
			my (@lines) = split(/\n/, "$new\n ");
			@lines = expand(@lines);
			if ($sys ne 'default' && $directive_overrides{$sys}{DEFAULT}) {
				for my $line (@lines) {
					$line .= " (DEFAULT)" 
						if $line =~ /(\S+)/ && $directive_overrides{$sys}{DEFAULT} eq $1;
				}
			}
			$new = join("\n", @lines);
			$new =~ s/\n $//;

			write_file("$tftpboot/$menudir/bootmsg.$menu.$sys", $new);
			$directive_overrides{$sys}{$menu} = "$menudir/bootmsg.$menu.$sys";
		} elsif ($menus{$menu}) {
			$directive_overrides{$sys}{$menu} = "$menudir/bootmsg.$menu.default"
		}
	}
	$directive_overrides{$sys}{F0} = $directive_overrides{$sys}{DISPLAY};
	$directive_overrides{$sys}{F10} = $directive_overrides{$sys}{DISPLAY};

	# write config files

	my $directives = '';
	for my $d (sort keys %directives) {
		next if exists $directive_overrides{$sys}{$d};
		$directives .= "$d\t$directives{$d}\n";
	}
	for my $d (sort keys %{$directive_overrides{$sys}}) {
		$directives .= "$d\t$directive_overrides{$sys}{$d}\n";
	}

	my $cust = <<END;
#
# This file was generated by $0 from $template.
# It controlls the boot of "$sys" (@{$system_originals{$sys}})
# at @{$systems{$sys}}
#
END

	$cust .= $directives;
	$cust .= $body;


	my $new = '';

	var_sub(\$cust, \$new, \%repl, 0, "main config file");

	unlink("$tftpboot/$cfg/$sys");
	write_file("$tftpboot/$cfg/$sys", $new);

	for my $addr (@{$systems{$sys}}) {
		if ($sys ne $addr) {
			unlink("$tftpboot/$cfg/$addr");
			symlink($sys, "$tftpboot/$cfg/$addr");
		}
	}
}

sub var_sub
{
	my ($raw, $cooked, $vars, $levels, $context) = @_;

	if ($levels > $max_levels) {
		warn "Exceeded maximum recursion levels $context";
		return;
	}

	pos($$raw) = 0;
	while ($$raw =~ m/\G(.*?)\$\((\S+)\)/gsc) {
		$$cooked .= $1;
		if (exists $vars->{$2}) {
			my $v = $vars->{$2};
			var_sub(\$v, $cooked, $vars, $levels+1, "expanding \$($2)");
		}
	}
	$$cooked .= substr($$raw, pos($$raw), length($$raw)-pos($$raw));
}

sub readconfig
{
	my($input) = @_;
	local($.);
	open my $ifh, "<", $input or die "open $input: $!";
	MAIN:
	while(<$ifh>) {
		chomp;
		s/\s+$//;
		if (/^\s*$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			$body .= "$_\n";
		} elsif (/^\s*#[\s#]/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			$body .= "$_\n";
		} elsif (/^(($directivesrx)\s+(\S.*))/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# PROMPT 1
			#
			my ($line, $global, $value) = ($1, $2, $3);
			$directives{$global} = $value;
			if ($global =~ /^$menurx$/) {
				$menus{$global} = $value;
			} 
		} elsif (/^LABEL\s+(\S+)/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# LABEL disk
			#	# ITEM F1-dell1		localboot (NORMAL DEFAULT)
			#	# ITEM F1		localboot
			#	# ITEM dell1		localboot (NORMAL DEFAULT)
			#	# ITEM 			localboot
			#	LOCALBOOT 0
			#
			my $label = $1;
			warn "LABEL $label duplicated at $input:$. and $labels{$label}" if $labels{$label};
			$labels{$label} = "$input:$.";
			$body .= "$_\n";
			while(<$ifh>) {
				redo MAIN if /^\S/;
				$body .= $_;
				if (     /^\s+#\s*ITEM\s+($menurx\S*)\s+<(\S+)>\s+(\S.*)/) {
					#
					# ITEM F1 <item-name> display
					#
					addmenuitem($input, $1, $2, $3);
				} elsif (/^\s+#\s*ITEM\s+($menurx\S*)\s+(\S.*)/) {
					#
					# ITEM F1 display
					#
					addmenuitem($input, $1, $label, $2);
				} elsif (/^\s+#\s*ITEM\s+<(\S+)>\s+(\S.*)/) {
					#
					# ITEM <item-name> display
					#
					addmenuitem($input, $lastmenu, $1, $2);
				} elsif (/^\s+#\s*ITEM\s+(\S.*)/) {
					#
					# ITEM <item-name> display
					#
					addmenuitem($input, $lastmenu, $label, $1);
				} elsif (/^\s+KERNEL\s+(\S+)/) {
					check_kernel($input, $1);
				}
			}
		} elsif (/^#MENU\s+(\S+)\s+\$\((\S+)\)\s*$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #MENU F1 $(dellboxes)
			# ...
			# #END
			#
			my ($menu, $var) = ($1, $2);
			my $buf = readmenu($input, $ifh, $menu);
			addmenu($input, $menu, $buf, var => $var);
			$lastmenu = $menu;
		} elsif (/^#MENU\s+(\S+)\s+(\S+)\s*$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #MENU F1 dell3
			# ...
			# #END
			#
			my ($menu, $system) = ($1, $2);
			my $buf = readmenu($input, $ifh, $menu);
			addmenu($input, $menu, $buf, system => $system);
			$lastmenu = $menu;
		} elsif (/^#MENU\s+(\S+)\s*$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #MENU F1
			# ...
			# #END
			#
			my $menu = $1;
			my $buf = readmenu($input, $ifh, $menu);
			addmenu($input, $menu, $buf);
			$lastmenu = $menu;
		} elsif (/^#SYSTEM\s+(\S+)\s+(\S+)/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #SYSTEM	01-00-06-5b-3a-31-d1 dell3
			#
			my ($addr, $name) = ($1, $2);
			my $orig = $addr;
			push(@{$system_originals{$name}}, $orig);
			if ($addr =~ /^$hexrx:$hexrx:$hexrx:$hexrx:$hexrx:$hexrx$/) {
				# ethernet
				$addr =~ s/:/-/g;
				$addr = "01-$addr";
				$addr = lc($addr);
			} elsif ($addr =~ /^\d+\.\d+\.\d+\.\d+$/) {
				# ip
				$addr = join('', map { sprintf("%02x", $_) } split(/\./, $addr));
				$addr = uc($addr);
			}
				
			die "systems must not be named *.gen ($name at $input:$.)\n" if $name =~ /\.gen$/;
			die "systems must not have / in their name ($name at $input:$.)\n" if $name =~ /\//;
			die "systems must not start with . ($name at $input:$.)\n" if $name =~ /^\./;
			warn "Duplicate system name ($name at $input:$.)\n" if $sysaddrs{$name};
			$sysaddrs{$addr} = $name;
			push(@{$systems{$name}}, $addr);
		} elsif (/^#FOR\s+\$\((\S+)\)\s+#SET\s+(\S+)\s+(\S.*)$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #FOR $(dellboxes) #SET kboot 77
			#
			my ($cvar, $var, $val) = ($1, $2, $3);
			for my $sys (keys %systems) {
				next unless $var_overrides{$sys}{$cvar};
				$var_overrides{$sys}{$var} = $val;
			}
		} elsif (/^#FOR\s+(\S+)\s+#SET\s+(\S+)\s+(\S.*)$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #FOR dell3 #SET kboot 77
			#
			$var_overrides{$1}{$2} = $3;
		} elsif (/^#FOR\s+\$\((\S+)\)\s+($directivesrx)(?:\s+(\S.*))?$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #FOR $(dells) SERIAL 0 9600 0x003
			#
			my ($cvar, $directive, $val) = ($1, $2, $3);
			$val = '' unless defined $val;
			for my $sys (keys %systems) {
				next unless $var_overrides{$sys}{$cvar};
				$directive_overrides{$sys}{$directive} = $val;
			}
		} elsif (/^#FOR\s+(\S+)\s+($directivesrx)(?:\s+(\S.*))?$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #FOR dell3 SERIAL 0 9600 0x003
			#
			$directive_overrides{$1}{$2} = defined $3 ? $3 : '';
		} elsif (/^#SET\s+(\S+)\s+(\S.*)$/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			#
			# #SET kboot 77
			#
			$vars{$1} = $2;
		} elsif (/^#INCLUDE\s+(\S+)/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			my $subconfig = $1;
			my $found;
			for my $x ($tftpboot, "$tftpboot/$cfg") {
				if (-d "$x/$subconfig") {
					for my $f (sort read_dir("$x/$subconfig")) {
						next unless -f "$x/$subconfig/$f";
						readconfig("$x/$subconfig/$f");
					}
					$found = 1;
					last;
				}
				if (-f "$x/$subconfig") {
					readconfig("$x/$subconfig");
					$found = 1;
					last;
				}
			}
			die "could not find #INCLUDE file $subconfig (from $input:$.)" unless $found;
		} elsif (/^#[A-Z]{2,100}/) {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			warn "Unknown directive at $input:$.: $_";
		} else {
			printf STDERR "AT %d:$_", __LINE__ if $debug > 3;
			warn "Could not parse line at $input:$.: $_";
		}
	}
	close($ifh);
}

sub addmenuitem
{
	my ($input, $menu, $label, $display) = @_;
	printf STDERR "addmenuitem(menu = %s, label = %s, display = %s, from = %d)\n", $menu, $label, $display, (caller(0))[2] if $debug & 2;
	my $buf = sprintf($menufmt, $label, $display);
	if ($menu =~ /^($menurx)-\$\((\S+)\)$/) {
		addmenu($input, $menu, $buf, var => $1);
	} elsif ($menu =~ /^($menurx)-(\S+)$/) {
		addmenu($input, $menu, $buf, system => $1);
	} elsif ($menu =~ /^($menurx)$/) {
		addmenu($input, $menu, $buf);
	} else {
		warn "bad #MENU control on line $input:$.";
	}
}

sub readmenu
{
	my ($input, $fd, $menu) = @_;
	warn "Illegal menu name '$menu' at $input:$." unless $menu =~ /^$menurx$/;
	my $buf;
	while(<$fd>) {
		last if /^#END$/;
		warn "missing #END at $input:$.?" if /^#[A-Z]{2,100}/;
		$buf .= $_;
	}
	return $buf;
}

sub addmenu
{
	my ($input, $menu, $buf, %opts) = @_;
	return unless $buf;
	warn "Illegal menu name '$menu' at $input:$." unless $menu =~ /^$menurx$/;
	if ($opts{var}) {
		my $var = $opts{var};
		for my $sys (keys %systems) {
			next unless $var_overrides{$sys}{$var};
			$menu_overrides{$sys}{$menu} ||= $menus{$menu};
			$menu_overrides{$sys}{$menu} .= $buf;
		}
	} elsif ($opts{systems}) {
		my $system = $opts{system};
		warn "No system $system at $input:$." unless $systems{$system};
		$menu_overrides{$system}{$menu} ||= $menus{$menu};
		$menu_overrides{$system}{$menu} .= $buf;
	} else {
		for my $sys (keys %menu_overrides) {
			next unless exists $menu_overrides{$sys}{$menu};
			$menu_overrides{$sys}{$menu} .= $buf;
		}
		$menus{$menu} .= $buf;
	}
}


my %kchecked;
sub check_kernel
{
	my ($input, $kernel) = @_;
	return if $kernel =~ /\$\(\w+\)/; # TODO: delay the check to later
	return if $kchecked{$kernel}++;
	my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat("$tftpboot/$kernel");
	if (! -e _) {
		warn "No '$kernel' file (referenced on line $input:$.)\n";
		return;
	} elsif (! ($mode & 04) && ! $uid != getpwnam('nobody')) {
		warn "Kernel '$kernel' is probably not readable (referenced at $input:$.)";
		return;
	}
}

sub usage
{
	return <<END;
Usage: $0 [--tftpboot dir] [--template file] [--debug level]
--tftpboot 	Specify root of tftp boot area (if not $tftpboot)
--template	Specify template file for (if not $template)
--debug		Specify debug level (if not $debug)
END
}

no warnings;
'completed';

__END__

=head1 NAME

 genpxelinux.pl - generate pxelinux configuration files

=head1 SYNOPSIS

 genpxelinux.pl [--tftpboot dir] [--template file] [--debug level]

=head1 DESCRIPTION

Genpxelinux.pl generates pxelinux configuration files.  Pxelinux 
uses simple config files that do not have any sort of conditional
support or macro expansion.  Pxelinux generally either loads a 
default configuration file or one that is specific to a particular
machine.

Genpxelinux.pl will generate multiple configuration files from one
template.  It will also generate the menu files that are displayed
to users.

The alternatives to using genpxelinux.pl to generate configuration
files for pxelinux is to either make them by hand or use something
like menu.c32 to provide menus. 

=head1 EXAMPLE CONFIGURATION FILE

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


=head1 MACROS 

Genpxelinux.pl supports the following macros and directives.

=over 4

=item #SYSTEM address system-name

The C<#SYSTEM> directive tells genpxelinux.pl to generate a 
configuration file for the system that asks from a particular
address.   All related configuration entries use the system name.

Pxelinux asks for configuration using a somewhat strange way
of writing ethernet mac addresses: 01-hh-hh-hh-hh-hh-hh.  The
#SYSTEM parameter will accept the pxelinux version or you can
write the address in the more usual HH:HH:HH:HH:HH:HH format.

Pxelinuxalso looks things up by their IP address written 
in hex.  And shortened one hex digit at a time.  The #SYSTEM
parameter will accept IP addresses written in the normal 
dotted-quad format and convert them to the pxelinux hex format.

=item #SET name value

Set a macro to expand to a particular value.  Macro expansion
is done with C<$(name)>.  Macros are expanded in both the 
configuration file and in menus. 

Macros are allowed in directives in a couple of places.  Where
they are used in directives, their value is checked at the time
the directive is parsed. 

Normally, macros are expanded just before the configuration files
and menus are written.

Undefined macros expand to the emtpy string and do not generate
a warning.

The C<$> macro is pre-set to C<$>.  C<$($)> expands to C<$>.

=item #FOR system-name #SET name value

Set a macro for a specific system.  

=item #FOR $(name1) #SET name2 value

For each system, if the macro $(name1) is defined, set the $(name2) 
macro.  Macros are can be defined on a per-system basis so this might 
be used to set further options for a group of systems.

=item #FOR system-name DIRECTIVE

Pxelinux defines directives for its configuration file.  The directive
that is most likely to be overridden is the C<DEFAULT> directive that
specifies the default boot action.

=item #FOR $(name) DIRECTIVE

For each system, set the pxelinux directive if $(name) is defined.

=item #MENU menu-name

Append the following lines (until C<#END>) to the named menu.
The menu names are: F1 F2 F3 F4 F5 F6 F7 F8 F9 DISPLAY.  DISPLAY
is the default menu that is automatically shown at startup.

Genpxelinux.pl forces Menu F10 to be the same as initial menu
(DISPLAY). 

Pxelinux supports some additional menus beyond F10 but these 
directives are not currently supported by genpxelinux.pl.

Tabs will be converted to spaces because pxelinux doesn't display
tabs correctly on most consoles.

=item #MENU menu-name system-name

Append the following lines to the named menu for a particular system.

=item #MENU menu-name $(macro)

For each system, append the following lines to the named menu 
if $(macro) is defined.

=item #INCLUDE filename

Parse filename as an additional configuration template.  If filename
happens be a directory, parse all of the files in the directory.

=back

=head2 LABEL SECTIONS

Within a LABEL section, the following macros are supported:

=over 4

=item #ITEM item_description

Add to the last menu modified by a C<#MENU> directive a line like:

 item_name		item_description

The C<item_name> comes from the word after C<LABEL>.

=item #ITEM menu_name item_description

Add to a particular menu (F1 .. F9 or DISPLAY).

=item #ITEM menu_name-system_name item_description.

Add to a particular menu for a particular system.

=item menu_name-$(macro) item_description.

For each system, add to a particular menu if $(macro) is defined.

=item #ITEM <item_name> item_description

Override the item_name and add to the last menu modified 
by a C<#MENU> directive.

=item #ITEM menu_name-system_name <item_name> item_description.

Override the item_name and 
add to a particular menu for a particular system.

=item #ITEM menu_name-$(macro) <item_name> item_description.

Override the item_name and 
for each system, add to a particular menu if $(macro) is defined.

=back

=head1 FILES

The default locations for things are:

 /tftpboot/pxelinux.cfg/template.gen
 /tftpboot/pxelinux.cfg/default
 /tftpboot/pxelinux.cfg/IP&ethernet-addresses
 /tftpboot/menus/*

=head1 SEE ALSO

L<http://syslinux.zytor.com/pxe.php>

=head1 LICENSE

Copyright (C) 2007 David Muir Sharnoff <cpan@dave.sharnoff.org>
Copyright (C) 2012 Google, Inc.
This module may be used and distributed on the same terms
as Perl itself.

