
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME		=> 'genpxelinux.pl',
	DISTNAME	=> 'Linux-Btldr-Pxelinux',
	VERSION_FROM	=> 'genpxelinux.pl',
	dist		=> { COMPRESS => 'gzip', SUFFIX => 'gz' },
	EXE_FILES       => [ 'genpxelinux.pl' ],
	PREREQ_PM	=> {
		'File::Slurp'	=> 0,
		'Getopt::Long'	=> 0,
	},
	PM		=> {
		'genpxelinux.pl'	=> 'Linux::Bootloader::Pxelinux.pm',
	},
	BUILD_REQUIRES	=> {
		'FindBin'	=> 0,
		'File::Temp'	=> 0,
		'Test::More'	=> 0,
		'Test::Output'	=> 0,
	},
	($] >= 5.005 
		?	
			(
				ABSTRACT	=> 'generate configuration files for pxelinux',
				AUTHOR		=> 'David Muir Sharnoff <cpan@dave.sharnoff.org>',
				META_MERGE	=> {
					resources  => {
						repository => 'http://github.com/muir/genpxelinux.pl',
					},
				},
			) 
		: ()
	),
	'dist'   => {COMPRESS=>'gzip', SUFFIX=>'gz'}
);


package MY;

sub postamble {
    <<"END_OF_POSTAMBLE";

pm_to_blib: README

README: genpxelinux.pl
\tpod2text genpxelinux.pl >README

END_OF_POSTAMBLE
}

