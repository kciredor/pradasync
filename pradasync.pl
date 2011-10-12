#!/usr/bin/perl

###############################################################################################
#
# Prada Phone Sync
#
# Syncs the Apple Address Book with the Prada Phone Book
# (c) 2007 Roderick Schaefer
#
###############################################################################################


# address book includes (req.: "Mac::Glue", "Device::SerialPort", gluemac <addressbook>)
use Mac::Glue ':glue';
use Mac::Apps::Launch;

# modem
use Device::SerialPort;

# encodings
use MIME::Base64;
use Encode 'from_to';

# cursor positioning
use POSIX;
use Term::Cap;


###############################################################################################
#
# Globals
#
###############################################################################################

$debug		= 0;
$version	= "v0.1";
$dbfile		= "pradasync.db";

# Conflict situation (both phone and computer changed) -> Set to '1' for the phone to be copied to computer.
$phonePriority	= 1;

my $wasRunning;
my $glue;

my( @ab, @pb, @db );
my %ab_changes_del = ();
my %pb_changes_del = ();
my %db_changes_del = ();
my $pbcountAdd = 0;
my $pbcountDel = 0;
my $pbcountChange = 0;
my $abcountAdd = 0;
my $abcountDel = 0;
my $abcountChange = 0;


###############################################################################################
#
# Main()
#
###############################################################################################

# intro
initTermCap();
clear_screen();
print "\n####################################################\n";
print "  Prada Phone Sync $version (c) 2007 Roderick Schaefer\n";
print "####################################################\n\n";
print "[" . getTime() . "]\tStarting Sync\n\n";

# read apple addressbook
print "[" . getTime() . "]\t* Reading Apple Address Book\n";
@ab = readAddressBook();
gotoXY( 54, 7 );
print "DONE               \n";

# read prada phonebook
print "[" . getTime() . "]\t* Reading Prada Phone Book\n";
@pb = readPhoneBook();
gotoXY( 54, 8 );
print "DONE               \n";

# read database
print "[" . getTime() . "]\t* Reading database\n";
readDatabase();
gotoXY( 54, 9 );
print "DONE\n";

# sync!
print "[" . getTime() . "]\t* Syncing ...\n";
sync();
gotoXY( 54, 10 );
print "DONE\n";

# debug
if( $debug ) { debugOutput(); }

# backup old database
print "[" . getTime() . "]\t* Backing up current database\n";
unless( $debug ) { backupDatabase(); }
gotoXY( 54, 11 );
print "DONE\n";

# write new database
print "[" . getTime() . "]\t* Writing new database\n";
unless( $debug ) { writeDatabase(); }
gotoXY( 54, 12 );
print "DONE\n";

# write apple addressbook
print "[" . getTime() . "]\t* Writing addressbook changes\n";
unless( $debug ) { writeAddressBook(); }
gotoXY( 54, 13 );
print "DONE     [a:$abcountAdd/c:$abcountChange/d:$abcountDel]\n";

# write prada phonebook
print "[" . getTime() . "]\t* Writing phonebook changes\n";
unless( $debug ) { writePhoneBook(); }
gotoXY( 54, 14 );
print "DONE     [a:$pbcountAdd/c:$pbcountChange/d:$pbcountDel]\n\n";

# finish / close
print "[" . getTime() . "]\tSync complete!\n\n\n";

exit 0;


###############################################################################################
#
# Helper functions
#
###############################################################################################

sub gotoXY {

	my( $x, $y ) = @_;    $tcap->Tgoto( 'cm', $x, $y, *STDOUT );

} 


sub clear_screen {

	$tcap->Tputs( 'cl', 1, *STDOUT );

}


sub initTermCap {

	$| = 1;
	$delay = ( shift() || 0 ) * 0.005;
	my $termios = POSIX::Termios->new();
	$termios->getattr;
	my $ospeed = $termios->getospeed;
	$tcap = Term::Cap->Tgetent ( { TERM => undef, OSPEED => $ospeed } );
	$tcap->Trequire( qw( cl cm cd ) );

}


sub getTime {

	($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
	$year = 1900 + $yearOffset;
	$month++;

	$hour = "0$hour" if length( $hour ) == 1;
	$minute = "0$minute" if length( $minute ) == 1;
	$second = "0$second" if length( $second ) == 1;

	return "$hour:$minute:$second";

}


sub trimQuotes { 

	my $s = shift;
	$s =~ s/^\"*//;
	$s =~ s/\"*$//;
	return $s;

}


sub trimSpaces { 

	my $s = shift;
	$s =~ s/^\s*//;
	$s =~ s/\s*$//;
	return $s;

}


sub writereadModem {

	my $write = shift;
	my $lookfor = shift;

	$modem->lookclear;
	$modem->write( "$write\r" );

	my $STALL_DEFAULT=10; # how many seconds to wait for new input
	my $timeout=$STALL_DEFAULT;

	my $chars=0;
	my $buffer="";
	
	while ($timeout>0) {

		my ($count,$saw)=$modem->read(255); # will read _up to_ 255 chars
		if ($count > 0) {
			$chars+=$count;
			$buffer.=$saw;
			if( index( $buffer, $lookfor ) > -1 ) { last; }
       		} else {
			$timeout--;
		}
	 }

	if ($timeout==0) {
       		die "\n\nSYNC HALTED: Modem read error: did not receive proper reply, waited $STALL_DEFAULT seconds.\n\n";
	}

	return $buffer;

}


sub phonenumberCount {

	$nr1 = shift;
	$nr2 = shift;
	$nr3 = shift;
	$nr4 = shift;

	$count = 0;

	$count++ if $nr1 != "";
	$count++ if $nr2 != "";
	$count++ if $nr3 != "";
	$count++ if $nr4 != "";

	return $count;

}


sub debugOutput {

	open( X, ">debug.log" );

	print X "addressbook changes (additions have empty id, group):\n";
	for $entry( @ab_changes ) {
		print X "[ @$entry ]\n";
	}
	while ( my ($key, $value ) = each( %ab_changes_del ) ) {
		print X "REMOVE: $key => $value\n";
	}

	print X "\nprada changes (additions have empty id, group):\n";
	for $entry ( @pb_changes ) {
		print X "[ @$entry ]\n";
	}
	while ( my ($key, $value ) = each( %pb_changes_del ) ) {
		print X "REMOVE: $key => $value\n";
	}

	print X "\ndatabase deletions (not changes):\n";
	#foreach $entry( @db_changes ) { #db_changes not used
	#	print X "$entry\n";
	#}
	while ( my ($key, $value ) = each( %db_changes_del ) ) {
		print X "REMOVE: $key => $value\n";
	}

	close( X );

}


###############################################################################################
#
# Database functions
#
# 2D-ARRAY: id, groupid, name, t:mobile, t:home, t:work, t:fax, email, memo
#
# id and groupid are unused but reserved for *Book compatibility
#
###############################################################################################


sub readDatabase {

	# One empty person (same for address book, phonebook - because phonebook id's start at 1)
	push @db, "RESERVED";

	# See if database exists, if not: ignore (first sync will create database)
	if( -e $dbfile ) {

		# Open database
		open( D, $dbfile ) or die( "\n\nCould not open database (file: $dbfile) for reading, HALT." );

		# id index
		undef %db_id;
		$pos = 0;

		# Read database
		while( <D> ) {

			chomp;
			( $id, $groupid, $name, $mobile, $home, $work, $fax, $email, $memo ) = split( /,/ );
			@person = ( $id, $groupid, $name, $mobile, $home, $work, $fax, $email, $memo );
			
			$pos++;
			$db_id{ $person[ 2 ] } = $pos;

			push @db, [ @person ];

		}

		# Close database
		close( D );

	}

}


sub writeDatabase {

	# open database for writing
	open( D, ">$dbfile" ) or die( "\n\nCould not open database (file: $dbfile) for writing, HALT." );

	# write contents (all @db array)
	for $i ( 1 .. $#db ) {

		$ln = '0,0,';	# reserved (id,group)

		for $j ( 2 .. $#{ $db[ $i ] } ) {
			$ln .= $db[ $i ][ $j ];
			$ln .= "," if $j < $#{ $db[ $i ] };
		}

		$skip = 0;

		# cleanup db: entry in DB, not in AB and not in PB: skip
		if( ( ! $ab_id{ $db[ $i ][ 2 ] } ) && ( ! $pb_id{ $db[ $i ][ 2 ] } ) ) {

			$skip = 1;

		}

		# if entry is in db_changes_del: skip
		$skip = 1 if defined $db_changes_del{ $db[ $i ][ 2 ] };

		# write!
		print D $ln . "\n" unless $skip == 1;

	}		

	# close database
	close( D);

}


sub backupDatabase {

	$dbfile_backup = $dbfile . ".previous";

	if( -e $dbfile ) {

		if( -e $dbfile_backup ) {

			unlink( $dbfile_backup ) || die "\n\nCould not remove old backup copy of the database!\n\n";

		}
		
		rename( $dbfile, $dbfile.".previous" ) || die "\n\nCould not save a backup copy of the database!\n\n";

	}

}


sub writeNewDatabase {

	# SHOULD NOT BE USED - USE EMPTY DATABASE ON FIRST SYNC!

	print "[" . getTime() . "]  ! Database does not exist, creating new\t";
	open( D, ">$dbfile" ) or die( "\n\nCould not open database (file: $dbfile) for writing, HALT." );

	for $i ( 0 .. $#db ) {

		$ln = '';

		for $j ( 2 .. $#{ $ab[ $i ] } ) {
			$ln .= $ab[ $i ][ $j ];
			$ln .= "," if $j < $#{ $ab[ $i ] };
		}

		print D $ln . "\n";

	}
	print "DONE\n";
	close( D );

}


###############################################################################################
#
# Read *Book functions
#
# Currently supported books:
#
# - Apple Address Book
# - Prada Phone Book
#
# Functions return:
#
# 2D-ARRAY: id, groupid, name, t:mobile, t:home, t:work, t:fax, email, memo
#
###############################################################################################


# read Apple Address Book
sub readAddressBook {

	# access apple addressbook
	$wasRunning = 1;
	$glue = Mac::Glue->new( 'Address Book' );
	$id = $glue->{ ID };

	if( !IsRunning( $id ) ){

		$wasRunning = 0;
		$glue->open();
		$glue->close( $glue->prop( 'window' ) ) or warn $^E;

	}

	# keep count
	$abRead = 0;
	$abReadTotal = $glue->prop( 'people' )->count;

	my @people = $glue->obj( 'people' )->get;

	# add one empty contact, because prada phone id's start at 1	
	push @ab, "RESERVED";

	# id indexing
	undef %ab_id;
	$pos = 0;

	foreach my $entry (  @people ) {

		# cleanup
		$mobile = '';  $home = ''; $work = ''; $fax = ''; $email = ''; $notes = '';

		# get home email (we use fixed 'home' email as email)
		my @emails=$entry->prop('email')->get;

		$readEmail = 0;

		foreach my $emailt (@emails) {
			my $addr=$emailt->prop( 'value' )->get;
			my $type=$emailt->prop( 'label' )->get;

			if( ( $type eq "home" ) && ( ! $readEmail ) ) {

				$readEmail = 1;
				$email = $addr;

			}

		}

		# get phone numbers (we use 'home' fax as fax)
		my @phones=$entry->prop( 'phone' )->get;

		$readMobile	= 0;
		$readHome	= 0;
		$readWork	= 0;
		$readFax	= 0;

		foreach my $phone ( @phones ) {
			my $number=$phone->prop( 'value' )->get;
			my $type=$phone->prop( 'label' )->get;

			if( ( $type eq "mobile" ) && ( ! $readMobile ) ) {

				$mobile = $number;
				$readMobile = 1;

			}
			if( ( $type eq "home" ) && ( ! $readHome ) ) {

				$home = $number;
				$readHome = 1;

			}
			if( ( $type eq "work" ) && ( ! $readWork ) ) {

				$work = $number;
				$readWork = 1;

			}
			if( ( $type eq "Fax" ) && ( ! $readFax ) ) {

				$fax = $number;
				$readFax = 1;

			}

		}

		# strip spaces from numbers
		$mobile	= trimSpaces( $mobile );
		$home	= trimSpaces( $home );
		$work	= trimSpaces( $work );
		$fax	= trimSpaces( $fax );

		# get notes field, max 1 line, 80 chars
		$notes = $entry->prop( 'note' )->get;
		$notes = '' if $notes eq 'msng';
		$notes =~ s/(\r\n|\r|\n)/ /g;
		if( length( $notes ) > 80 ) {
			$notes = substr( $notes, 0, 80 );
		}

		# get id, name, group
		$id	= $entry->prop( 'id' )->get;
		$name	= $entry->prop( 'name' )->get;
		$group	= '';

		# create entry
		@person = ( $id, $group, $name, $mobile, $home, $work, $fax, $email, $notes );

		# dupecheck + save position
		if( $ab_id{ $name } > 0 ) {

			push @ab_dupes, $name;

		} else {

			$pos++;
			$ab_id{ $name } = $pos;

		}

		# save entry to 2d-array
		push @ab, [ @person ];

		# counter
		$abRead++;
		gotoXY( 54, 7 );
		$percDone = int( 100 / $abReadTotal * $abRead );
		print "[$abRead/$abReadTotal] - $percDone%\n";

	}

	# if dupes found, list and exit
	if( $#ab_dupes + 1 > 0 ) {

		print "ERROR\n\n\nOne or more duplicate names were found in the computer addressbook.\nSyncing with the Prada phone does not permit duplicates.\n\nPlease remove these duplicates and try again:\n";

		foreach( @ab_dupes ) {

			print "- $_\n";

		}

		print "\nSyncing halted.\n\n";

		exit 1;

	}

	# done
	return @ab;

}


###############################################################################################


# read Prada Phone Book
sub readPhoneBook {

	# counter (not really)
	gotoXY( 54, 8 );
	print "BUSY..";

	# init modem
	@fn = glob( "/dev/cu.usbmodem*" );
	$device = @fn[0];
	if ( $device eq "" ) {
		die( "\n\nMake sure the phone is connected with the USB cable and that the connectivity usb mode is set to data, not storage.\n\n" );
	}
	$modem = Device::SerialPort->new( $device ) || die( "Cannot connect to the Prada phone modem interface! HALTED.\n\n" );
	$modem->read_char_time(0);     # don't wait for each character
	$modem->read_const_time(1000); # 1 second per unfulfilled "read" call

	# init modem
	writereadModem( 'ATE0', 'OK' );					# just a test
	writereadModem( 'AT+CMEE=1', 'OK' );				# unknown
	writereadModem( 'AT+PABEG', 'OK' );				# displays 'sending' dialog on the phone
	writereadModem( 'AT+SBEG', 'OK' );				# 'S' begin (session begin?)
	writereadModem( 'AT+CSCS="Base64"', 'OK' );			# set encoding to Base64
	writereadModem( 'AT+CPBS="PM"', 'OK' );				# set phonebook source to Phone Memory

	# read contacts
	$raw = writereadModem( 'AT+CPBR="1,1000"', "\r\nOK\r\n" );	# read contacts from phone
	@peopleraw = split( /\r\n\r\n/, $raw );
	# delete last 'OK' from array
	delete $peopleraw[ $#raw ];

	# add one empty contact, because prada phone id's start at 1	
	push @pb, "RESERVED";
	
	# id indexing
	undef %pb_id;
	$pos = 0;

	# split
	for my $personraw( @peopleraw ) {

		@person = '';
		$idx = index( $personraw, "+CPBR:" );
		( $id, $groupid, $name, $nameend, $mobile, $mobileend, $home, $homeend, $work, $workend, $email, $emailend, $fax, $faxend, $memo, $memoend ) = split( /,/, substr( $personraw, $idx + 6 ) );

		# decode base64
		$name = decode_base64( $name );
		$email = decode_base64( $email );
		$memo = decode_base64( $memo );

		# mac address book uses Mac Roman format (western)
		from_to( $name, "iso-8859-1", "MacRoman");
		from_to( $email, "iso-8859-1", "MacRoman");
		from_to( $memo, "iso-8859-1", "MacRoman");

		# multibyte to single
		$name =~ s/\x00//g;
		$email =~ s/\x00//g;
		$memo =~ s/\x00//g;

		# dupecheck + save position
		if( $pb_id{ $name } > 0 ) {

			push @pb_dupes, $name;

		} else {

			$pos++;
			$pb_id{ $name } = $pos;

		}

		# remove quotes from entries besides string entries (which are the phonenumbers, e.g.: mobile, home, work, fax)
		$mobile	= trimQuotes( $mobile );
		$home	= trimQuotes( $home );
		$work	= trimQuotes( $work );
		$fax	= trimQuotes( $fax );

		# save 2d-array
		@person = ( $id, $groupid, $name, $mobile, $home, $work, $fax, $email, $memo );
		push @pb, [ @person ];

	}

	# de-init modem and close connection
	$res = writereadModem( 'AT+SEND', 'OK' );			# 'S' end (session end?)
	$res = writereadModem( 'AT+PAEND', 'OK' );			# hide 'sending' dialog on the phone
	undef $modem;							# close modem connection / cleanup

	# if dupes found, list and exit
	if( $#pb_dupes + 1 > 0 ) {

		print "ERROR\n\n\nOne or more duplicate names were found in the Prada phonebook.\nSyncing with the Prada phone does not permit duplicates.\n\nPlease remove these duplicates and try again:\n";

		foreach( @pb_dupes ) {

			print "- $_\n";

		}

		print "\nSyncing halted.\n\n";

		exit 1;

	}

	# done
	return @pb;

}


###############################################################################################
#
# SYNC ALGO
#
###############################################################################################


sub sync {

	# SYNC FUNCTION
	# builds: @pb_changes, @ab_changes, NOT @db_changes (applied directly to @db)
	# and: %pb_changes_del, %ab_changes_del, %db_changes-del

	# 1-A. loop PB -> entry not in AB? -> entry in DB = delete from PB, DB | entry not in DB = add to AB, DB

	for $i ( 1 .. $#pb ) {	# always from 1 .. X, because entry 0 = reserved

		if( ! $ab_id{ $pb[ $i ][ 2 ] } > 0 ) {	# if current entry name does not have an id higher than 0 in other book

			if( ! $db_id{ $pb[ $i ][ 2 ] } > 0 ) { # if current entry name does not have an id higher than 0 in database
				
				# create entry
				@newentry = @{ $pb[ $i ] }; @newentry[ 0 ] = ""; @newentry[ 1 ] = "";

				# add to AB
				push @ab_changes, [ @newentry ];
				$abcountAdd++;

				# add to DB
				push @db, [ @newentry ];

			} else {

				# remove from PB
				$pb_changes_del{ $pb[ $i ][ 2 ] } = $pb[ $i ][ 0 ];
				$pbcountDel++;

				# remove from DB
				$db_changes_del{ $pb[ $i ][ 2 ] } = $db_id{ $pb[ $i ][ 2 ] };

			}

		}

	}
	

	# 1-B. loop AB, reversed: -> entry not in PB? -> entry in DB = delete from AB, DB | entry not in DB = add to PB, DB

	for $i ( 1 .. $#ab ) {

		if( ! $pb_id{ $ab[ $i ][ 2 ] } > 0 ) {	# if current entry name does not have an id higher than 0 in other book	(name = pos 2 in *books)

			if( ! $db_id{ $ab[ $i ][ 2 ] } > 0 ) { # if current entry name does not have an id higher than 0 in database (name = pos 0 in database)
				
				# if this AB-entry contains no numbers at all then skip (phone contacts must have at least 1 number entry)
				if( phonenumberCount( @{$ab[ $i ]}[3,4,5,6] ) > 0 ) {		# 3, 4, 5, 6 = mobile, home, work, fax entries

					# create entry
					@newentry = @{ $ab[ $i ] }; @newentry[ 0 ] = ""; @newentry[ 1 ] = "";

					# add to PB
					push @pb_changes, [ @newentry ] ;
					$pbcountAdd++;

					# add to DB
					push @db, [ @newentry ];

				}

			} else {

				# remove from AB
				$ab_changes_del{ $ab[ $i ][ 2 ] } = $ab[ $i ][ 0 ];
				$abcountDel++;

				# remove from DB
				$db_changes_del{ $ab[ $i ][ 2 ] } = $db_id{ $ab[ $i ][ 2 ] };

			}

		}

	}


	# 2. loop AB
	for $i ( 1 .. $#ab ) {

		$skip = 0;

		# 2-A. AB has no phone entries?

		if( phonenumberCount( @{$ab[ $i ]}[3,4,5,6] ) == 0 ) {

			if ( ! $pb_id{ $ab[ $i ][ 2 ] } > 0 ) {

				# AB has no numbers, PB entry does not exist --> skip

				$skip = 1;

			} else {

				if( $phonePriority ) {

					# NOTE: it's possible that someone removed all AB phone entries, and added a NEW phone entry (or changed an entry); with $phonePriority

					# look for phonenumber changes
					$confPhoneChanges = 0;

					if( $db_id { $ab[ $i ][ 2 ] } ) {

						# with DB

						for $j ( 4 .. 7 ) {

							# increase for every PB - DB change
							if( ! $pb[ $pb_id{ $ab[ $i ][ 2 ] } ][ $j ] eq $db[ $db_id{ $ab[ $i ][ 2 ] } ][ $j ] ) {

								$confPhoneChanges++;

							}

						}

					} else {

						# without DB

						$confPhoneChanges = phonenumberCount( @{$pb[ $pb_id{ $ab[ $i ][ 2 ] } ]}[3,4,5,6] );

					}

					if( $confPhoneChanges > 0 ) {

						$skip = 0;	# already was 0, but just to make sure it'll go through the sync loop some more :)

					} else {

						# remove from PB
						$pb_changes_del{ $ab[ $i ][ 2 ] } = $pb_id{ $ab[ $i ][ 2 ] };
						$pbcountDel++;
						# remove from DB (if it exists, if not: doesn't matter)
						$db_changes_del{ $ab[ $i ][ 2 ] } = $db_id{ $ab[ $i ][ 2 ] };				
						# no further processing
						$skip = 1;

					}

				} else {

					# AB has no numbers, PB entry exists --> delete from DB and PB, next time this one will skip [priority with AB]

					# remove from PB
					$pb_changes_del{ $ab[ $i ][ 2 ] } = $pb_id{ $ab[ $i ][ 2 ] };
					$pbcountDel++;
					# remove from DB (if it exists, if not: doesn't matter)
					$db_changes_del{ $ab[ $i ][ 2 ] } = $db_id{ $ab[ $i ][ 2 ] };				
					# no further processing
					$skip = 1;

				}

			}

		}


		# 2-B. skip if the entry is in the created AB-delete-HASH
		$skip = 1 if defined $ab_changes_del{ $ab[ $i ][ 2 ] };

		# 2-C. skip if the entry is still to be created in the phonebook
		$skip = 1 if ! $pb_id{ $ab[ $i ][ 2 ] };

		# 2-D. compare contents AB, PB - including combining contents
		if( $skip == 0 ) {


			# reset
			$dbcreate	= 0;
			$entryname	= $ab[ $i ][ 2 ];

			$ab_changed	= 0;
			$pb_changed	= 0;
			# $db_changed	= 0;	# not used, because db changes are applied to @db directly


			# compare
			# 1. beide ongelijk aan DB = AB en DB worden PB en AB+DB krijgen changed flag (als $phonePriority = 1), else:
			# 2. X ongelijk aan DB: Y en DB krijgen X en Y+DB krijgen changed flag
			for $j ( 3 .. $#{ $ab[ $i ] } ) {

				if( $db_id { $entryname } ) {

					# DB entry exists
					if( $ab[ $ab_id{ $entryname } ][ $j ] eq $db[ $db_id{ $entryname } ][ $j ] ) {

						# AB = DB

						if( $pb[ $pb_id{ $entryname } ][ $j ] eq $db[ $db_id{ $entryname } ][ $j ] ) {

							# >> AB = DB and PB = DB

							# do nothing

						} else {

							# >> AB = DB and PB != DB

							# AB en DB worden PB en AB krijgt changeflag
							$ab_changed = 1;
							$ab[ $ab_id{ $entryname } ][ $j ] = $pb[ $pb_id{ $entryname } ][ $j ];
							$db[ $db_id{ $entryname } ][ $j ] = $pb[ $pb_id{ $entryname } ][ $j ];

						}

					} else {

						# AB != DB

						if( $pb[ $pb_id{ $entryname } ][ $j ] eq $db[ $db_id{ $entryname } ][ $j ] ) {

							# >> AB != DB and PB = DB

							# PB en DB worden AB en PB krijgt changeflag
							$pb_changed = 1;
							$pb[ $pb_id{ $entryname } ][ $ j ] = $ab[ $ab_id{ $entryname } ][ $j ];
							$db[ $db_id{ $entryname } ][ $ j ] = $ab[ $ab_id{ $entryname } ][ $j ];

						} else {

							# >> AB != DB and PB != DB ( CONFLICT, give priority to phone if $phonePriority = 1 )

							if( $phonePriority ) {

								# AB en DB worden PB en AB krijgt changeflag
								$ab_changed = 1;
								$ab[ $ab_id{ $entryname } ][ $j ] = $pb[ $pb_id{ $entryname } ][ $j ];
								$db[ $db_id{ $entryname } ][ $j ] = $pb[ $pb_id{ $entryname } ][ $j ];

							} else {

								# PB en DB worden AB en PB krijgt changeflag
								$pb_changed = 1;
								$pb[ $pb_id{ $entryname } ][ $ j ] = $ab[ $ab_id{ $entryname } ][ $j ];
								$db[ $db_id{ $entryname } ][ $ j ] = $ab[ $ab_id{ $entryname } ][ $j ];

							}

						}

					}

				} else {

					# DB entry does not exist yet (first sync or both AB and PB had the same contact added manually); if AB == PB: add to DB, else: AB, DB = PB and ab_changed = 1;
					# checks for phone or ab priority
					$dbcreate = 1;
					if( $ab[ $ab_id{ $entryname } ][ $j ] eq $pb[ $pb_id{ $entryname } ][ $j ] ) {

						# pb = db, so add to db

						# < happens below >

					} else {

						# als ab leeg is: ab = pb | als ab vol is en pb is vol: $phonePriority, ab = pb | als ab vol is en pb is leeg: pb = ab

						# ab = empty  -> ab = pb
						if ( $ab[ $ab_id{ $entryname } ][ $j ] eq "" ) {

							$ab[ $ab_id{ $entryname } ][ $j ] = $pb[ $pb_id{ $entryname } ][ $j ];
							$ab_changed = 1;

						} else {

							# ab = something, pb = nothing -> ab = pb
							if( $pb[ $pb_id{ $entryname } ][ $j ] eq "" ) {

								$pb[ $pb_id{ $entryname } ][ $j ] = $ab[ $ab_id{ $entryname } ][ $j ];
								$pb_changed = 1;

							# ab = something, pb = something -> pb = ab
							} else {

								if( $phonePriority ) {

									$ab[ $ab_id{ $entryname } ][ $j ] = $pb[ $pb_id{ $entryname } ][ $j ];
									$ab_changed = 1;

								} else {

									$pb[ $pb_id{ $entryname } ][ $j ] = $ab[ $ab_id{ $entryname } ][ $j ];
									$pb_changed = 1;

								}

							}

						}

					}

				}

			}


			# if we are in db-creation mode (first time sync or AB and PB had the same contact added manually)
			if( $dbcreate == 1 ) {
		
				@entry = @{ $pb[ $pb_id{ $entryname } ] };
				push @db, [ @entry ];

			}

			# if phonebook has changes: write
			if( $pb_changed == 1 ) {

				@entry = @{ $pb[ $pb_id{ $entryname } ] };
				push @pb_changes, [ @entry ];
				$pbcountChange++;

			}

			# if addressbook has changes: write
			if( $ab_changed == 1 ) {
	
				@entry = @{ $ab[ $ab_id{ $entryname } ] };
				push @ab_changes, [ @entry ];
				$abcountChange++;

			}
			# end of entry loop in sync

		}

	}
	# end of last sync loop!

}


###############################################################################################
#
# Write *Book functions
#
###############################################################################################


sub writeAddressBook {

	# if we have no changes at all, return immediately
	$abChangesTotal = $abcountAdd + $abcountChange + $abcountDel;
	if( $abChangesTotal < 1 ) { return 0; }

	# keep count
	$abChangesDone = 0;


	# add new / update

	for $i ( 0 .. $#ab_changes ) {

		# ( $id, $groupid, $name, $mobile, $home, $work, $fax, $email, $memo ) = @entry;

		$id	= $ab_changes[ $i ][ 0 ];
		$group	= $ab_changes[ $i ][ 1 ];
		$name	= $ab_changes[ $i ][ 2 ];
		$mobile	= $ab_changes[ $i ][ 3 ];
		$home	= $ab_changes[ $i ][ 4 ];
		$work	= $ab_changes[ $i ][ 5 ];
		$fax	= $ab_changes[ $i ][ 6 ];
		$email	= $ab_changes[ $i ][ 7 ];
		$memo	= $ab_changes[ $i ][ 8 ];

		if( $id eq "" ) {

			# add new entry

			# split name
			$voornaam = "";
			$achternaam = "";
			( $voornaam, @achternaam ) = split( / /, $name );
			foreach( @achternaam ) { $achternaam .= " $_" };
			$achternaam =~ s/^ *//;

			# create person
			my $person = $glue->make( new => 'person', with_properties => {

				first_name => $voornaam,
				last_name => $achternaam,
				note => $memo

			} );

			# add phonenumbers

			if( ! $mobile eq "" ) {

				$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $mobile,
					label => 'mobile'

				});

			}

			if( ! $home eq "" ) {

				$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $home,
					label => 'home'
	
				});

			}

			if( ! $work eq "" ) {

				$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $work,
					label => 'work'

				});

			}

			if( ! $fax eq "" ) {

				$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $fax,
					label => 'Fax'
	
				});

			}

			# add emailaddress

			if( ! $email eq "" ) {

				$glue->make( new => 'email', at => location( end => $person->prop( 'emails' ) ), with_properties => {

					value => $email,
					label => 'home'

				});

			}


		} else {

			# modify entry

			$person = $glue->obj( person => whose( id => equals => $id ) );


			# set phone numbers (we use 'home' fax as fax)
			my @phones = $person->prop( 'phone' )->get;

			$setMobile = 0;
			$setHome = 0;
			$setWork = 0;
			$setFax = 0;

			foreach my $phone ( @phones ) {

				$type = $phone->prop( 'label' )->get;

				if( ( $type eq "mobile" ) && ( ! $setMobile ) ) {

					$setMobile = 1;
					if( $mobile eq "" ) {

						$phone->delete;

					} else {

						$phone->prop( 'value' )->set( to => ' ' . $mobile );

					}

				} elsif( ( $type eq "home" ) && ( ! $setHome ) ) {

					$setHome = 1;
					if( $home eq "" ) {

						$phone->delete;

					} else {

						$phone->prop( 'value' )->set( to => ' ' . $home );

					}

				} elsif( ( $type eq "work" ) && ( ! $setWork ) ) {

					$setWork = 1;
					if( $work eq "" ) {

						$phone->delete;

					} else {

						$phone->prop( 'value' )->set( to => ' ' . $work );

					}

				} elsif( ( $type eq "Fax" ) && ( ! $setFax ) ) {

					$setFax = 1;
					if( $fax eq "" ) {

						$phone->delete;

					} else {

						$phone->prop( 'value' )->set( to => ' ' . $fax );

					}

				}

			}

			if( ( ! $mobile eq "" ) && ( ! $setMobile ) ) {

					$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $mobile,
					label => 'mobile'

				});

			}
			if( ( ! $home eq "" ) && ( ! $setHome ) ) {

					$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $home,
					label => 'home'

				});

			}
			if( ( ! $work eq "" ) && ( ! $setWork ) ) {

					$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $work,
					label => 'work'

				});

			}
			if( ( ! $fax eq "" ) && ( ! $setFax ) ) {

					$glue->make( new => 'phone', at => location( end => $person->prop( 'phones' ) ), with_properties => {

					value => " " . $fax,
					label => 'Fax'

				});

			}


			# set home email (we use fixed 'home' email as email)
			$setEmail = 0;

			my @emails = $person->prop( 'email' )->get;

			foreach my $emailt (@emails) {

				my $type = $emailt->prop( 'label' )->get;
				if ( ( $type eq "home" ) && ( ! $setEmail ) ) {

					$setEmail = 1;

					if( $email eq "" ) {

						$emailt->delete;

					} else {

						$emailt->prop( 'value' )->set( to=> $email );

					}

				}

			}

			if( ( ! $email eq "" ) && ( ! $setEmail ) ) {

				$glue->make( new => 'email', at => location( end => $person->prop( 'emails' ) ), with_properties => {

					value => $email,
					label => 'home'

				});

			}

			# set note
			$person->prop( 'note' )->set( to => $memo );

		}

		# update counter
		$abChangesDone++;
		gotoXY( 54, 13 );
		$percDone = int( 100 / $abChangesTotal * $abChangesDone );
		print "[$abChangesDone/$abChangesTotal] - $percDone%\n";

	}


	# delete entries

	while ( my ($key, $value ) = each( %ab_changes_del ) ) {

		$entry = $glue->obj( person => whose( id => equals => $value ) );
		$entry->delete;

		# update counter
		$abChangesDone++;
		gotoXY( 54, 13 );
		$percDone = int( 100 / $abChangesTotal * $abChangesDone );
		print "[$abChangesDone/$abChangesTotal] - $percDone%\n";

	}


	# direct update (by saving right now) the screen of the Address Book app
	$glue->save_addressbook();

	# close if it wasn't open
	if( $wasRunning ) {

		$glue->quit;

	}

}


###############################################################################################


sub writePhoneBook {

	# if we have no changes at all, return immediately
	$pbChangesTotal = $pbcountAdd + $pbcountChange + $pbcountDel;
	if( $pbChangesTotal < 1 ) { return 0; }

	# keep count
	$pbChangesDone = 0;


	# modem command list
	my @commands;


	# add / update entries

	for $i ( 0 .. $#pb_changes ) {

		# ( $id, $groupid, $name, $mobile, $home, $work, $fax, $email, $memo ) = @entry;

		# split/get entry

		$id	= $pb_changes[ $i ][ 0 ];
		$group	= $pb_changes[ $i ][ 1 ];
		$name	= $pb_changes[ $i ][ 2 ];
		$mobile	= $pb_changes[ $i ][ 3 ];
		$home	= $pb_changes[ $i ][ 4 ];
		$work	= $pb_changes[ $i ][ 5 ];
		$fax	= $pb_changes[ $i ][ 6 ];
		$email	= $pb_changes[ $i ][ 7 ];
		$memo	= $pb_changes[ $i ][ 8 ];

		# naam, email and memo are ISO-8859-1 multibyte-base64 encoded, quoted

		$name	=~ s/(\w|\W)/$1\x00/g;					# widechar
		$name	.= "\x00\x00";						# widechar: trailing 00h,00h
		from_to( $name, "MacRoman", "iso-8859-1");			# characterset (iso-8859-1 = Latin1)
		$name	= encode_base64( $name );				# base64
		$name	=~ s/[\r|\n]//g;					# strip newlines
		$name	= "\"$name\"";						# quote

		if( ! $email eq "" ) {

			$email	=~ s/(\w|\W)/$1\x00/g;					# widechar
			$email	.= "\x00\x00";						# widechar: trailing 00h,00h
			from_to( $email, "MacRoman", "iso-8859-1");			# characterset (iso-8859-1 = Latin1)
			$email	= encode_base64( $email );				# base64
			$email	=~ s/[\r|\n]//g;					# strip newlines

		}
		$email = "\"$email\"";							# quote

		if( ! $memo eq "" ) {

			$memo	=~ s/(\w|\W)/$1\x00/g;					# widechar
			$memo	.= "\x00\x00";						# widechar: trailing 00h,00h
			from_to( $memo, "MacRoman", "iso-8859-1");			# characterset (iso-8859-1 = Latin1)
			$memo	= encode_base64( $memo );				# base64
			$memo	=~ s/[\r|\n]//g;					# strip newlines

		}
		$memo = "\"$memo\"";							# quote

		# phonenumbers (mobile, home, work, fax) need to be quoted and terminated

		$mobileend = '129';	$mobileend = '145' if $mobile =~ /\D/;
		$homeend = '129';	$homeend = '145' if $home =~ /\D/;
		$workend = '129';	$workend = '145' if $work =~ /\D/;
		$faxend = '129';	$faxend = '145' if $fax =~ /\D/;

		$mobile	= "\"$mobile\"";
		$home	= "\"$home\"";
		$work	= "\"$work\"";
		$fax	= "\"$fax\"";

		# empty group (addition)
		$group = '6' if $group eq "";

		# add or update is the same, empty or non-empty id
		# ( $id, $groupid, $name, $nameend, $mobile, $mobileend, $home, $homeend, $work, $workend, $email, $emailend, $fax, $faxend, $memo, $memoend )

		$entry = "AT+CPBW=$id,$group,$name,0,$mobile,$mobileend,$home,$homeend,$work,$workend,$email,0,$fax,$faxend,$memo,0";

		push @commands, $entry;

	}


	# delete entries, reversed order to preserve id's for now

	@ids = sort { $pb_changes_del{ $a } cmp $pb_changes_del{ $b } } keys %pb_changes_del;
	for( $i = $#ids; $i >= 0; $i-- ) {

		$cmd = "AT+CPBW=$pb_changes_del{ $ids[ $i ] }";
		push @commands, $cmd;

	}


	# init modem
	@fn = glob( "/dev/cu.usbmodem*" );
	$device = @fn[0];
	if ( $device eq "" ) {
		print "\n\nMake sure the phone is connected with the USB cable and that the connectivity usb mode is set to data, not storage.\n\n";
	}
	$modem = Device::SerialPort->new( $device ) || die( "Cannot connect to the Prada phone modem interface! HALTED.\n\n" );
	$modem->read_char_time(0);     # don't wait for each character
	$modem->read_const_time(1000); # 1 second per unfulfilled "read" call

	# init modem
	# writereadModem( 'ATE0', 'OK' );				# just a test
	# writereadModem( 'AT+CMEE=1', 'OK' );				# unknown
	# writereadModem( 'AT+PABEG', 'OK' );				# displays 'sending' dialog on the phone
	writereadModem( 'AT+SBEG', 'OK' );				# 'S' begin (session begin?)
	# writereadModem( 'AT+CSCS="Base64"', 'OK' );			# set encoding to Base64
	# writereadModem( 'AT+CPBS="PM"', 'OK' );			# set phonebook source to Phone Memory

	# execute modem commands! (walk through @commands)
	open( X, ">debug2.log" ) if $debug;
	for $command ( @commands ) {

		print X "$command\n" if $debug;
		writereadModem( $command, 'OK' );

		# update counter
		$pbChangesDone++;
		gotoXY( 54, 14 );
		$percDone = int( 100 / $pbChangesTotal * $pbChangesDone );
		print "[$pbChangesDone/$pbChangesTotal] - $percDone%\n";

	}
	close( X ) if $debug;

	# de-init modem and close connection
	$res = writereadModem( 'AT+SEND', 'OK' );			# 'S' end (session end?)
	# $res = writereadModem( 'AT+PAEND', 'OK' );			# hide 'sending' dialog on the phone
	undef $modem;							# close modem connection / cleanup

}


###############################################################################################
###############################################################################################
