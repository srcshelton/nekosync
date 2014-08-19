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

## Do not edit below this line

my $configured = undef;

my $width = ( ( $ENV{ COLUMNS } or 80 ) - 2 );
$width = 40 if $width < 40;

## Utility subroutines

sub ifverbose( $;$ ) {
	my ( $true, $false ) = @_;

	my $message = $verbose ? $true : $false;

	return undef if not $message;

	open ( my $OUT, ">&", STDOUT ) or die "FATAL:  Cannot dup STDOUT: $!\n";
	if( $message =~ m/^\S+:\s/sm ) {
		open ( my $OUT, ">&", STDERR ) or die "FATAL:  Cannot dup STDERR: $!\n";
	}
	return print $OUT $message;
} # ifverbose

sub ifnotverbose( $ ) {
	return ifverbose( undef, shift );
} # ifnotverbose

sub ifdebug( $ ) {
	return undef if not $debug;

	return print STDERR shift;
} # ifdebug

#
# Scary wrapper around open to redirect STDERR away from the console
#  - thanks, Paul! :)
#

sub qopen( *;$$ ) {
	$_[0] = gensym() unless( defined $_[0] );
	my $file = qualify_to_ref( shift, caller() );

	open( my $STDERR_SAVE, ">&", STDERR ) or die "FATAL:  Cannot dup STDERR: $!\n";
	open( STDERR, ">/dev/null" ) or die "FATAL:  Cannot open /dev/null: $!\n";

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

	die "$@\n" if $@;

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
		ifverbose( "WARN:   Cannot read from file \"$filename\": $!\n" );
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

die "FATAL:  Cannot find tar executable at $tar\n" if not -x $tar;
die "FATAL:  Cannot find tar executable at $get\n" if not -x $get;
die "FATAL:  Cannot find tar executable at $rsync\n" if not -x $rsync and not $useget;

$rsyncargs = join( ' ', $rsyncdefargs, $rsyncargs );

$width = undef if $debug;

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

sub removeoldfiles( $$$\@ ) {
	my ( $dloc, $oloc, $delete, $oldpackages ) = @_;

	my $counter = 0;
	my $deleted = FALSE;

	if( $oloc or $delete ) {
		if( scalar( @$oldpackages ) and not $safe ) {

			if( $deleted ) {
				if( not $delete ) {
					ifnotverbose( "\nMoving obsolete files         " );
					$counter = 0;
				}
			} else {
				if( $delete ) {
					ifnotverbose( "Removing obsolete files       " );
				} else {
					ifnotverbose( "Moving obsolete files         " );
				}
			}

			while( my $file = pop @$oldpackages ) {
				if( -d $file ) {
					ifverbose( "\"$file\" is a directory!\n", "!" );
					$counter++ if defined $width;
				} else {
					if( $delete ) {
						unlink( $file ) or die "FATAL:  Error unlinking \"$file\": $!\n" if not $pretend;
					} else {
						my $dest = "$dloc";
						$dest .= "/$oloc" if $oloc;
						#rename( $file, "$dest/" ) or die "FATAL:  Error moving $file - $!\n" if not $pretend;
						eval { system( "mv -f \"$file\" \"$dest/\"" ) == 0 or die "FATAL:  Error moving $file - $!\n" } if not $pretend;
					}
					ifverbose( "\"$file\" " . $delete ? "removed\n" : "moved\n", "." );
					$counter++ if defined $width;
				}
				if( defined $width && not $verbose ) {
					if( ( $counter + 30 ) > $width ) {
						$counter = 0;
						print STDOUT "\n" . " " x 30;
					}
				}
			}
			ifnotverbose( "\n" );
		}
	}

	return TRUE;
} # removeoldfiles

sub findorphanfiles( $\% ) {
	my ( $iloc, $instfiles ) = @_;
	my @deletions;

	ifnotverbose( "Checking for orphaned files   " );
	opendir( my $Inst, $iloc ) or die "FATAL:  Cannot opendir on \"$iloc\": $!\n";

	my $counter = 0;
	my @files = readdir( $Inst );
	while( my $file = pop @files ) {
		next if -d "$iloc/$file";
		next if $file =~ /^.(.)?$/;
		if( not exists $instfiles -> { $file } ) {
			push( @deletions, "$iloc/$file" );
			ifverbose( $file . " doesn't belong to any current package\n", "-" );
			$counter++ if defined $width;
		}
		if( defined $width && not $verbose ) {
			if( ( $counter + 30 ) > $width ) {
				$counter = 0;
				print STDOUT "\n" . " " x 30;
			}
		}
	}
	closedir( $Inst );
	ifnotverbose( "\n" );

	removeoldfiles( $iloc, undef, TRUE, @deletions );
	return TRUE;
} # findorphanfiles

sub unpackfiles( \@$$$ ) {
	my ( $files, $dloc, $iloc, $oloc ) = @_;
	my %instfiles;
	my %errors;
	my %messages;

	ifnotverbose( "Unpacking updated files       " );
	ifdebug( "\n" );
	my $counter = 0;
	foreach my $file ( sort( @$files ) ) {
		my $replace = FALSE;
		ifverbose( "Processing " . $file . "\n" );
		my $command = join( ' ', $tar, '-tvf', "$dloc/$file" , "|" );
		qopen( my $File, $command ) or die "FATAL:  Cannot open pipe to $tar: $!\n";
		while( <$File> ) {
			my @fields = split( /[[:space:]]+/ );
			if( scalar( @fields ) and $fields[ 0 ] =~ /^-/ ) {
				( my $filename = $fields[ 5 ] ) =~ s#^\./##;
				my $size = $fields[ 2 ];
				if( defined $instfiles{ $filename } ) {
					my ( $name ) = ( $file =~ m/^(.*)\.tardist$/ );
					$messages{ $file } = "$name clashes with files from another package";
				}
				$instfiles{ $filename } = $size;
				if( scalar( my $result = stat( "$iloc/$filename" ) ) ) {
					my $fsize = $result -> size;
					if( not ( $size eq $fsize ) ) {
						$replace = TRUE;
						my ( $name ) = ( $file =~ m/^(.*)\.tardist$/ );
						ifdebug( "Debug: $iloc/$filename from $name has changed from $size to $fsize\n" );
					}
				} else {
					$replace = TRUE;
					ifdebug( "Debug: stat() failed on $iloc/$filename\n" );
				}
			} else {
				$replace = TRUE;
				ifdebug( "Debug: Unknown format returned from $tar: \"@fields\"\n" );
			}
		}
		if( $@ ) {
			ifverbose( "WARN: Archive listing failed: $@\n", $debug ? "" : "!" );
			$counter++;
		} else {
			if( $replace ) {
				my $command = join( ' ', $tar, '-xf', "$dloc/$file", '-C', $iloc, '>/dev/null 2>&1' );
				if( not $pretend ) {
					ifverbose( "Unpacking $file\n" );
					eval { system( $command ) };
					if( $@ or $? ) {
						$errors{ $file } = "$file is corrupt and cannot be unpacked";
						ifverbose( "\nERROR: Unable to unpack $file: $@ ($?)\n", $debug ? "" : "!" );
						$counter++;
					} else {
						ifverbose( "Unpacked $file successfully\n", $debug ? "" : "+" );
						$counter++;
					}
				}
			} else {
				ifverbose( "Data from $file unchanged\n", $debug ? "" : "." );
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
		print STDERR "Warning: $message\n";
	}
	print STDERR "\n" if( %messages );
	print STDERR "\n" if( %errors and not %messages );
	foreach my $message ( sort( values( %errors ) ) ) {
		print STDERR "Error: $message\n";
	}
	print STDERR "\n" if( %errors );

	findorphanfiles( $iloc, %instfiles );
	return TRUE;
} # unpackfiles

sub getdist( $$$$ ) {
	my ( $dloc, $iloc, $oloc, $delete ) = @_;
	my $Index;
	my %md5sums;
	my @downloads;
	my @oldpackages;
	my $counter = 0;
	my $checksum;

	autoflush STDOUT TRUE;
	setupdirs( $dloc, $iloc, $oloc );
	chdir $dloc or die "FATAL:  Cannot chdir to \"$dloc\"\n";
	ifverbose( "Downloading $index from $mirror/ - please wait...", "Downloading index file, please wait..." );
	ifdebug( "\n" );

	{
		my $contents = undef;
		my $command = join( ' ', $get, $getargs, '-', $mirror . "/" . $index , "|" );
		qopen( my $File, $command ) or die "FATAL:  Cannot open pipe to $get: $!\n";
		while( <$File> ) {
			my @fields = split( /[[:space:]]+/ );
			if( scalar( @fields ) ) {
				my $filename = $fields[ 0 ];
				my $line = join( ' ', @fields );
				( my $sum = $line ) =~ s/^.*[[:space:]]([[:alnum:]]{32})[[:space:]].*$/$1/;
				if( $sum ) {
					$md5sums{ $filename } = $sum;
					ifdebug( "\nFound sum $sum for file $filename" );
				}
				$contents .= $line;
			}
		}
		close( $File );

		if( not %md5sums ) {
			die "\nFATAL: Specified directory $mirror/ is empty\n";
		}

		if( defined $contents ) {
			ifdebug( "\nGenerating MD5 sum of $index... " );
			my $digest = Digest::MD5 -> new();
			$digest -> add( $contents );
			$checksum = $digest -> hexdigest();
			$digest = undef;
			ifdebug( $checksum . "\n" );
		}
	}

	foreach my $file ( sort( keys( %md5sums ) ) ) {
		if( $file !~ /\.tardist$/ ) {
			delete $md5sums{ $file };
		}
	}
	ifverbose( " read " . keys( %md5sums ) . " packages\n", ( $debug ? "" : " done" ) . "\nChecking for updated packages " );
	ifdebug( "\n" );

	foreach my $file ( sort( keys( %md5sums ) ) ) {
		ifdebug( "Looking for " . $file . "\n" );
		if( -r $file ) {
			open( my $File, "<", $file ) or die "FATAL:  Cannot open " . $file . ": $!\n";
			my $digest = Digest::MD5 -> new();
			$digest -> addfile( $File );
			my $sum = $digest -> hexdigest();
			$digest = undef;
			if( $sum eq $md5sums{ $file } ) {
				ifverbose( $file . " is up to date\n", $debug ? undef : "." );
				$counter++ if defined $width;
			} else {
				ifverbose( $file . ": Digest $sum does not match archive digest " . $md5sums{ $file } . "\n", "*" );
				push( @downloads, $file );
				$counter++ if defined $width;
			}
		} else {
			push( @downloads, $file );
			ifverbose( $file . ": Does not exist on local filesystem\n", "+" );
			$counter++ if defined $width;
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
				ifverbose( $file . ": Removed from remote archive\n", "-" );
				$counter++ if defined $width;
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
	ifnotverbose( "\n" );
	print STDOUT "\n" . scalar( @oldpackages) . " files are obsolete and " . scalar( @downloads ) . " files have been modified\n\n";

	while( my $file = pop @downloads ) {
		my $command = join( ' ', $get, $getargs, '-', $mirror . "/" . $file, "|" );
		print STDOUT "Downloading  $file  ";
		qopen( my $InFile, $command ) or die "FATAL:  Cannot open pipe to $get: $!\n";
		open( my $OutFile, ">", $dloc . "/" . $file ) or die "FATAL:  Cannot open $file for writing: $!\n";
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
		if( close( $InFile ) ) {
			print STDOUT "\bdone\n";
		} else {
			ifnotverbose( "\b\n" );
			print STDERR "Fetch error: $? - Bad descript.ion?\n";
		}
	}

	ifdebug( "\nGenerating second MD5 sum of $index..." );
	{
		my $contents = undef;
		my $command = join( ' ', $get, $getargs, '-', $mirror . "/" . $index , "|" );
		qopen( my $File, $command ) or die "FATAL:  Cannot open pipe to $get: $!\n";
		while( <$File> ) {
			my @fields = split( /[[:space:]]+/ );
			if( scalar( @fields ) ) {
				my $line = join( ' ', @fields );
				$contents .= $line;
			}
		}
		close( $File );

		if( defined $checksum ) {
			my $digest = Digest::MD5 -> new();
			$digest -> add( $contents );
			if( $checksum ne $digest -> hexdigest() ) {
				die "FATAL: $index changed during operation - please try again...\n"
			}
			$digest = undef;
			ifdebug( " checksums match\n\n" );
		} else {
			print STDERR "ERROR: Cannot generate checksums - was a valid index downloaded?\n";
		}
	}

	my @files = keys( %md5sums );
	unpackfiles( @files, $dloc, $iloc, $oloc );
	removeoldfiles( $dloc, $oloc, $delete, @oldpackages );
	return TRUE;
} # getdist

sub syncdist( $$$ ) {
	my ( $dloc, $iloc, $oloc ) = @_;
	my @tardists;
	my $counter = 0;

	autoflush STDOUT TRUE;
	setupdirs( $dloc, $iloc, $oloc );
	chdir $dloc or die "FATAL:  Cannot chdir to \"$dloc\"\n";
	ifverbose( "Starting rsync connection to $rmirror - please wait... \n", "Starting rsync, please wait...\n" );
	my $command = join( ' ', $rsync, $rsyncargs, "--backup-dir '$distloc/$oldloc'", $rmirror , "$distloc" );
	ifverbose( "Executing $command\n" );
	system( $command ) == 0 or die "rsync failed: $?\n";

	print STDOUT "\n";
	print STDOUT "Reading directory contents    ";

	opendir( my $Dist, $dloc ) or die "FATAL:  Cannot opendir on \"$dloc\": $!\n";
	{
		my @files = readdir( $Dist );
		while( my $file = pop @files ) {
			next if -d $file;
			next if $file !~ /\.tardist$/;
			push( @tardists, "$file" );
			ifnotverbose( "." );
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

	unpackfiles( @tardists, $dloc, $iloc, $oloc );
	return TRUE;
} # syncdist

if( $useget ) {
	getdist( $distloc, $instloc, $oldloc, $delete );

	if( $extra ) {
		print STDOUT "\n";
		$mirror =~ s#/current$#/beta#;
		getdist( "$distloc/beta", "$instloc/beta", undef, TRUE );
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
