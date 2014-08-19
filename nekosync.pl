#!/usr/nekoware/bin/perl -w
#
# nekosync - based on tardist2inst, with added MD5 checking...
#

use strict;
use Digest::MD5;
use IO::Handle;
use File::stat;

use Symbol qw( qualify_to_ref gensym );

sub TRUE  { 1 };
sub FALSE { 0 };

my $name = 'nekosync';

## Variables below here can be over-ridden in the config file

my $distloc = '/usr/tmp/nekoware/dist';
my $instloc = '/usr/tmp/nekoware/inst';
my $oldloc  = 'obsolete';
my $tmploc  = '/usr/tmp';

my $gnupath = '/usr/nekoware/bin';

my ( $tar, $get, $rsync );
eval { chomp( $tar = `$gnupath/bash -c "type -p tar"` ) };
eval { chomp( $get = `$gnupath/bash -c "type -p wget"` ) };
eval { chomp( $rsync = `$gnupath/bash -c "type -p rsync"` ) };

my $getargs = '-q --passive-ftp -nd -np -O';
my $mirror = 'http://www.nekochan.net/nekoware/current';
my $index = 'descript.ion';
my $extra = TRUE;
my $rsyncdefargs = "-bultS --delete-after -T $tmploc --suffix=\\'\\' --numeric-ids";
my $rsyncargs = '';
my $rmirror = 'rsync.nekochan.net::nekoware/current/*.tardist';
my $useget = TRUE;

my $verbose = FALSE;
my $debug = FALSE;
my $safe = TRUE;
my $pretend = TRUE;
my $delete = FALSE;

my $launchswmgr = TRUE;

my $configured = undef;

## Do not edit below this line

my $width = ( ( $ENV{ COLUMNS } or 80 ) - 2 );
$width = 40 if $width < 40;

#
# Scary wrapper around open to redirect STDERR away from the console
#  - thanks, Paul! :)
#

sub qopen( *;$$ ) {
	$_[0] = gensym() unless( defined $_[0] );
	my $file = qualify_to_ref( shift, caller() );

	open( my $STDERR_SAVE, ">&", STDERR ) or die "FATAL:  Cannot dup STDERR";
	open( STDERR, ">/dev/null" ) or die "FATAL:  Cannot reopen /dev/null";

	my ( $return, $bang);
	eval {
		if ( scalar @_ == 1 ) {
			$return = open( $file, shift );
		} else {
			$return = open( $file, shift, shift );
		}
		$bang = $!;
	};

	open( STDERR, ">&", $STDERR_SAVE );

	die $@ if $@;

	$! = $bang;
	return $return;
}

#
# Source user variables...
#

sub readconfig( $ ) {
	my $filename = shift;
	my $File;

	if( not open( $File, "<", $filename ) ) {
		print STDERR "WARN:   Cannot read from file \"$filename\": $!\n" if $verbose;
	} else {
		if( wantarray ) {
			local $/ = "";
			my @list = <$File>;
			close $File;
			return @list;
		} else {
			local $/ = undef;
			my $string = <$File>;
			close $File;
			return $string;
		}
	}
} # readconfig

my $extconf;

$extconf = "/usr/nekoware/etc/$name.conf" if -r "/usr/nekoware/etc/$name.conf";
$extconf = "/etc/$name.conf" if -r "/etc/$name.conf";
$extconf = $ENV{ HOME } . "/.$name.conf" if -r $ENV{ HOME } . "/.$name.conf";

if( $extconf ) {
	eval readconfig( $extconf )
} else {
	print STDERR "NOTICE: No external configuration file found, using defaults...\n";
}

die "nekosync has not yet been configured - please\n  edit $extconf\n  and ensure sane defaults are set before\n  re-running\n" if( defined $configured );

die "FATAL:  Cannot find tar executable at $tar" if not -x $tar;
die "FATAL:  Cannot find tar executable at $get" if not -x $get;
die "FATAL:  Cannot find tar executable at $rsync" if not -x $rsync and not $useget;

$rsyncargs = join( ' ', $rsyncdefargs, $rsyncargs );

sub safemkdir( $ );
sub safemkdir( $ ) {
	my $dir = shift;

	( my $parent = $dir ) =~ s#/+#/#g;
	$parent =~ s#/[^/]+$##;

	if( not -d $parent ) {
		my $result = safemkdir( $parent );
		if( defined $result ) {
			if( $result ) {
				# mkdir failed
				return TRUE;
			} else {
				# safe mode is on
				return FALSE;
			}
		}
	}

	if( not -d $dir ) {
		if( $safe ) {
			return FALSE;
		} else {
			return TRUE if( not mkdir( $dir ) );
		}
	}

	return undef;
} # safemkdir

sub setupdirs( $$$ ) {
	my ( $dloc, $iloc, $oloc ) = @_;

	my %dirs = ( "$dloc", "Distribution/download", "$iloc", "Installation" );
	$dirs{ "$dloc/$oloc" } = "Backup" if $oloc;
	foreach my $dir ( keys( %dirs ) ) {
		my $desc = $dirs{ $dir };
		if( defined( my $error = safemkdir( "$dir" ) ) ) {
			if( $error ) {
				print STDERR "FATAL:  $desc directory \"$dir\" does not exist\n";
				die "        and cannot be created\n";
			} else {
				print STDERR "FATAL:  $desc directory \"$dir\" does not exist\n";
				die "        Safe mode enabled - not creating\n";
			}
		}
	}

	return TRUE;
} # setupdirs

sub removeoldfiles( $$$\@\@ ) {
	my ( $dloc, $oloc, $delete, $oldpackages, $oldfiles ) = @_;

	my $counter = 0;
	my $deleted = FALSE;

	if( scalar( @$oldfiles ) and not $safe ) {
		$deleted = TRUE;
		print STDOUT "Removing obsolete files       " if not $verbose;
		while( my $file = pop @$oldfiles ) {
			if( -d $file ) {
				if( $verbose ) {
					print STDOUT "\"$file\" is a directory!\n";
				} else {
					print STDOUT "!";
					$counter++ if defined $width;
				}
			} else {
				unlink( $file ) or die "FATAL:  Error unlinking \"$file\": $!\n" if not $pretend;
				if( $verbose ) {
					print STDOUT "\"$file\" removed\n";
				} else {
					print STDOUT ".";
					$counter++ if defined $width;
				}
			}
			if( defined $width && not $verbose ) {
				if( ( $counter + 30 ) > $width ) {
					$counter = 0;
					print STDOUT "\n" . " " x 30;
				}
			}
		}
	}

	if( $oloc or $delete ) {
		if( scalar( @$oldpackages ) and not $safe ) {

			if( $deleted ) {
				if( not $delete ) {
					print STDOUT "\nMoving obsolete files         " if not $verbose;
					$counter = 0;
				}
			} else {
				if( $delete ) {
					print STDOUT "Removing obsolete files       " if not $verbose;
				} else {
					print STDOUT "Moving obsolete files         " if not $verbose;
				}
			}

			while( my $file = pop @$oldpackages ) {
				if( -d $file ) {
					if( $verbose ) {
						print STDOUT "\"$file\" is a directory!\n";
					} else {
						print STDOUT "!";
						$counter++ if defined $width;
					}
				} else {
					if( $delete ) {
						unlink( $file ) or die "FATAL:  Error unlinking \"$file\": $!\n" if not $pretend;
					} else {
						my $dest = "$dloc";
						$dest .= "/$oloc" if $oloc;
						#rename( $file, "$dest/" ) or die "FATAL:  Error moving $file - $!\n" if not $pretend;
						eval { system( "mv \"$file\" \"$dest/\"" ) or die "FATAL:  Error moving $file - $!\n" } if not $pretend;
					}
					if( $verbose ) {
						if( $delete ) {
							print STDOUT "\"$file\" removed\n";
						} else {
							print STDOUT "\"$file\" moved\n";
						}
					} else {
						print STDOUT ".";
						$counter++ if defined $width;
					}
				}
				if( defined $width && not $verbose ) {
					if( ( $counter + 30 ) > $width ) {
						$counter = 0;
						print STDOUT "\n" . " " x 30;
					}
				}
			}
			print STDOUT "\n" if not $verbose;
		}
	}

	return TRUE;
} # removeoldfiles()

sub findorphanfiles( $\%\@ ) {
	my ( $iloc, $instfiles, $deletions ) = @_;

	print STDOUT "Checking for orphaned files   " if not $verbose;

	opendir( my $Inst, $iloc ) or die "FATAL:  Cannot opendir on \"$iloc\": $!\n";

	my $counter = 0;
	my @files = readdir( $Inst );
	while( my $file = pop @files ) {
		next if -d "$iloc/$file";
		next if $file =~ /^.(.)?$/;
		if( not exists $instfiles -> { $file } ) {
			push( @$deletions, "$iloc/$file" );
			if( $verbose ) {
				print STDOUT $file . " doesn't belong to any current package\n";
			} else {
				print STDOUT "-";
				$counter++ if defined $width;
			}
		}
		if( defined $width && not $verbose ) {
			if( ( $counter + 30 ) > $width ) {
				$counter = 0;
				print STDOUT "\n" . " " x 30;
			}
		}
	}
	closedir( $Inst );

	print STDOUT "\n" if not $verbose;

	return TRUE;
} # findorphanfiles

sub unpackfiles( \@$$$\@ ) {
	my ( $files, $dloc, $iloc, $oloc, $oldpackages ) = @_;
	
	my @oldfiles;
	my %instfiles;
	my %messages;

	print STDOUT "Unpacking updated files       " if not $verbose;
	my $counter = 0;
	foreach my $file ( sort( @$files ) ) {
		my $replace = FALSE;
		print STDOUT "Processing " . $file . "\n" if $verbose;
		my $command = join( ' ', $tar, '-tvf', "$dloc/$file" , "|" );
		open( my $File, $command ) or die "FATAL:  Cannot open pipe to $tar: $!";
		while( <$File> ) {
			my @fields = split( /[[:space:]]+/ );
			if( scalar( @fields ) and $fields[ 0 ] =~ /^-/ ) {
				( my $filename = $fields[ 5 ] ) =~ s#^\./##;
				my $size = $fields[ 2 ];
				if( defined $instfiles{ $filename } ) {
					$messages{ $file } = "$file clashes with files from another package";
				}
				$instfiles{ $filename } = $size;
				if( scalar( my $result = stat( "$iloc/$filename" ) ) ) {
					my $fsize = $result -> size;
					if( not ( $size eq $fsize ) ) {
						$replace = TRUE;
						print STDERR "Debug:  $iloc/$filename from $file has changed from $size to $fsize\n" if $debug;
					}
				} else {
					$replace = TRUE;
					print STDERR "Debug:  stat() failed on $iloc/$filename\n" if $debug;
				}
			} else {
				$replace = TRUE;
				print STDERR "Debug:  Unknown format returned from $tar: \"@fields\"\n" if $debug;
			}
		}
		if( $replace ) {
			my $command = join( ' ', $tar, '-xf', "$dloc/$file", '-C', $iloc );
			if( $verbose ) {
				print STDOUT "Unpacking $file\n";
			} else {
				print STDOUT "+";
				$counter++;
			}
			eval { system( $command ) } if not $pretend;
			die "\nFATAL:  Unable to unpack $file: $@\n" if $@;
		} else {
			if( $verbose ) {
				print "Data from $file unchanged\n";
			} else {
				print STDOUT ".";
				$counter++;
			}
		}
		if( defined $width && not $verbose ) {
			if( ( $counter + 30 ) > $width ) {
				$counter = 0;
				print STDOUT "\n" . " " x 30;
			}
		}
	}

	print STDOUT "\n";
	print STDERR "\n" if( %messages );
	foreach my $message ( sort( values( %messages ) ) ) {
		print STDERR "QA Warning: $message\n";
	}
	print STDERR "\n" if( %messages );

	findorphanfiles( $iloc, %instfiles, @oldfiles );
	removeoldfiles( $dloc, $oloc, $delete, @$oldpackages, @oldfiles );

	return TRUE;
} # unpackfiles

sub getdist( $$$$ ) {
	my ( $dloc, $iloc, $oloc, $delete ) = @_;

	my $Index;
	my %md5sums;
	my @downloads;
	my @oldpackages;
	my $counter = 0;

	autoflush STDOUT TRUE;

	setupdirs( $dloc, $iloc, $oloc );

	chdir $dloc or die "FATAL:  Cannot chdir to \"$dloc\"\n";

	if( $verbose ) {
		print STDOUT "Downloading $index from $mirror/ - please wait... ";
	} else {
		print STDOUT "Downloading index file, please wait...";
	}

	my $command = join( ' ', $get, $getargs, '-', $mirror . "/" . $index , "|" );
	qopen( my $File, $command ) or die "FATAL:  Cannot open pipe to $get: $!";
	while( <$File> ) {
		my @fields = split( /[[:space:]]+/ );
		if( scalar( @fields ) ) {
			my $filename = $fields[ 0 ];
			my $line = join( ' ', @fields );
			(my $sum = $line ) =~ s/^.*[[:space:]]([[:alnum:]]{32})[[:space:]].*$/$1/;
			if( $sum ) {
				$md5sums{ $filename } = $sum;
				print STDERR "Debug:  Found sum $sum for file $filename\n" if $debug;
			}
		}
	}
	close( $File );

	print STDOUT " done\n" if not $verbose;

	foreach my $file ( sort( keys( %md5sums ) ) ) {
		if( $file !~ /\.tardist$/ ) {
			delete $md5sums{ $file };
		}
	}
	print STDOUT "read " . keys( %md5sums ) . " packages\n" if $verbose;

	print STDOUT "\nChecking for updated packages " if not $verbose;

	foreach my $file ( sort( keys( %md5sums ) ) ) {
		print STDOUT "Debug:  Looking for " . $file . "\n" if $debug;
		if( -r $file ) {
			open( my $File, "<", $file ) or die "FATAL:  Cannot open " . $file . ": $!\n";
			my $digest = Digest::MD5 -> new();
			$digest -> addfile( $File );
			my $sum = $digest -> hexdigest();
			if( $sum eq $md5sums{ $file } ) {
				if( $verbose ) {
					print STDOUT $file . " is up to date\n";
				} else {
					print STDOUT "." if not $verbose;
					$counter++ if defined $width && not $verbose;
				}
			} else {
				print STDOUT $file . ": Digest $sum does not match archive digest " . $md5sums{ $file } . "\n" if $verbose;
				push( @downloads, $file );
				print STDOUT "*" if not $verbose;
				$counter++ if defined $width && not $verbose;
			}
		} else {
			push( @downloads, $file );
			if( $verbose ) {
				print STDOUT $file . ": Does not exist on local filesystem\n";
			} else {
				print STDOUT "+" if not $verbose;
				$counter++ if defined $width && not $verbose;
			}
		}
		if( defined $width && not $verbose ) {
			if( ( $counter + 30 ) > $width ) {
				$counter = 0;
				print STDOUT "\n" . " " x 30;
			}
		}
	}

	opendir( my $Dist, $dloc ) or die "FATAL:  Cannot opendir on $dloc: $!\n";
	{
		my @files = readdir( $Dist );
		while( my $file = pop @files ) {
			next if -d "$dloc/$file";
			next if $file !~ /\.tardist$/;
			if( not( defined $md5sums{ $file } ) ) {
				push( @oldpackages, "$dloc/$file" );
				if( $verbose ) {
					print STDOUT $file . ": Removed from remote archive\n";
				} else {
					print STDOUT "-";
					$counter++ if defined $width;
				}
			}
			if( defined $width && not $verbose ) {
				if( ( $counter + 30 ) > $width ) {
					$counter = 0;
					print STDOUT "\n" . " " x 30;
				}
			}
		}
		closedir( $Dist );
	}

	print STDOUT "\n" if not $verbose;

	print STDOUT "\n" . scalar( @oldpackages) . " files are obsolete and " . scalar( @downloads ) . " files have been modified\n\n";

	while( my $file = pop @downloads ) {
		my $command = join( ' ', $get, $getargs, '-', $mirror . "/" . $file, "|" );
		printf STDOUT "Downloading  $file  ";
		qopen( my $InFile, $command ) or die "FATAL:  Cannot open pipe to $get: $!\n";
		open( my $OutFile, ">", $dloc . "/" . $file ) or die "FATAL:  Cannot open $file for writing: $!";
		my $counter = 0;
		my $iteration = 0;
		my @characters = ( '/', '-', '\\', '|' );
		while( my $data = <$InFile> ) {
			if( 0 eq ( $iteration++ % 20 ) ) {
				print STDOUT "\b" . $characters[ $counter++ % scalar( @characters ) ];
			}
			print $OutFile $data;
		}
		close( $OutFile );
		close( $InFile );
		printf STDOUT "\bdone\n";
	}

	my @files = keys( %md5sums );
	unpackfiles( @files, $dloc, $iloc, $oloc, @oldpackages );

	return TRUE;
} # getdist

sub syncdist( $$$ ) {
	my ( $dloc, $iloc, $oloc ) = @_;

	autoflush STDOUT TRUE;

	setupdirs( $dloc, $iloc, $oloc );

	chdir $dloc or die "FATAL:  Cannot chdir to \"$dloc\"\n";

	if( $verbose ) {
		print STDOUT "Starting rsync connection to $rmirror - please wait... \n";
	} else {
		print STDOUT "Starting rsync, please wait...\n";
	}

	my $command = join( ' ', $rsync, $rsyncargs, "--backup-dir '$distloc/$oldloc'", $rmirror , "$distloc" );
	print STDOUT "Executing $command\n" if $verbose;
	system( $command ) == 0 or die "rsync failed: $?";

	my @tardists;
	my @oldpackages;
	my $counter = 0;

	print STDOUT "\n";
	print STDOUT "Reading directory contents    ";

	opendir( my $Dist, $dloc ) or die "FATAL:  Cannot opendir on \"$dloc\": $!\n";
	{
		my @files = readdir( $Dist );
		while( my $file = pop @files ) {
			next if -d $file;
			next if $file !~ /\.tardist$/;
			push( @tardists, "$file" );
			print STDOUT "." if not $verbose;
			$counter++ if defined $width;
			if( defined $width && not $verbose ) {
				if( ( $counter + 30 ) > $width ) {
					$counter = 0;
					print STDOUT "\n" . " " x 30;
				}
			}
		}
		closedir( $Dist );
	}

	print STDOUT "\n";

	unpackfiles( @tardists, $dloc, $iloc, $oloc, @oldpackages );

	return TRUE;
} # syncdist

if( $useget ) {
	getdist( $distloc, $instloc, $oldloc, $delete );

	if( $extra ) {
		print STDOUT "\n";
		$mirror =~ s#/current$#/beta#;
		getdist( "$distloc/beta", "$instloc/beta", undef, TRUE );

		#$mirror =~ s#/nekoware/beta$#/contrib/foetz#i;
		#getdist( "$distloc/foetz", "$instloc/foetz", undef, TRUE );
	}
} else {
	syncdist( $distloc, $instloc, $oldloc );
}

if( $launchswmgr ) {
	print STDOUT "Launching SoftwareManager... ";
	system( "/usr/sbin/SoftwareManager -f $instloc" );
}

print STDOUT "\n$name finished at " . gmtime() . "\n";

exit 0;

# vi: set nowrap ts=4:
