
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME		=> 'Linux::Bootloader::Pxelinux',
	DISTNAME	=> 'Linux-Btldr-Pxelinux',
	VERSION_FROM	=> 'genpxelinux.pl',
	dist		=> { COMPRESS => 'gzip', SUFFIX => 'gz' },
	EXE_FILES       => [ 'genpxelinux.pl' ],
	PREREQ_PM	=> {
		'File::Slurp'	=> 0,
		'Getopt::Long'	=> 0,
	},
);

