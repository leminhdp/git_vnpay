#!/usr/bin/perl

use File::ReadBackwards; # EPEL RPM: perl-File-ReadBackwards.noarch 
use Getopt::Long;
use Time::Piece; # RHEL package: perl-Time-Piece
use File::Find;


my %table;

$table{'SEARCH'} = [0,0,0];
$table{'GET_TOKEN'} = [0,0,0];
$table{'GET_SEAT'} = [0,0,0];
$table{'BOOK'} = [0,0,0];
$table{'PAYMENT'} = [0,0,0];


$table{'ID_TIMEOUT'} = '';
$table{'ID_FAILED'} = '';
$table{'TIME_PROCESS'} = 0;


	
$time_pattern = '%Y-%m-%d %H:%M:%S';
$warning = 1;
$critical = 1;
$time_position = 0;

#2018-07-20 10:01:28, action:SEARCH, cinema:57, code:00, time_process:0
#2018-07-20 10:01:37, action:GET_TOKEN, sessioncode:963304, code:00, time_process:0
#2018-07-19 07:12:21, action:GET_SEAT, queryId:217180, code:00, time_process:1
#2018-07-19 08:52:26, action:BOOK, queryId:217013, code:00, time_process:0
#2018-07-19 07:14:25, action:PAYMENT, queryId:217320, code:00, time_process:7

# 2018-11-06 02:38:08, action:SEARCH, code:00, time_process:2
# 2018-11-04 23:03:14, action:GET_TOKEN, code:00,time_process:2
# 2018-11-04 23:03:14, action:GET_SEAT, code:00, time_process:2, query_id: 1005839
# 2018-11-04 23:03:28, action:BOOK, code:00, time_process:2, book_id: 1396
# 2018-11-04 23:03:50, action:PAYMENT, code:00, time_process:2, book_id: 1396

$pattern_timeout = "action:(SEARCH|GET_TOKEN|GET_SEAT|BOOK|PAYMENT), code:(99|08), time_process:(\\d+), (query_id|book_id): (\\d+)";
$pattern_successed = "action:(SEARCH|GET_TOKEN|GET_SEAT|BOOK|PAYMENT), code:(00), time_process:(\\d+), (query_id|book_id): (\\d+)";
$pattern_failed = "action:(SEARCH|GET_TOKEN|GET_SEAT|BOOK|PAYMENT), code:(01), time_process:(\\d+), (query_id|book_id): (\\d+)";


$result = GetOptions (
            "logfile=s" => \$logfile, # string e.g. "/var/log/messages" 
            "interval=i" => \$interval, # int e.g. 30 for half an hour
            "timepattern=s" => \$time_pattern, #string e.g. '%Y-%m-%d %H:%M:%S'
			"timeposition=i" => \$time_position, # int, each line is split into string on the space character, this provides the index of the first string block for the time
            "warning|w=i" => \$warning, # int e.g. 3
			"critical|c=i" => \$critical, # int e.g. 5
			"debug|d|vv" => \$debug, # flag/boolean
			"verbose|v" => \$verbose, # flag/boolean
            "help|h|?" => \$usage # flag/boolean  - is help called?
            ); 
            


my $now = localtime;
$oldestDate = $now - $interval*60;
if ($debug) { print "Now: $now and tzoffset: ". ($now)->tzoffset ."\n"; }
if ($debug) { print "Oldest date: $oldestDate and tzoffset: ". ($oldestDate)->tzoffset ."\n"; }


$hits_successed = 0; # number of matches for the regex within the log files will be counted in this variable
$hits_failed = 0;
$hits = 0;

$validFileNames = 0; # number of files that match the given filename
my @dateFields = $time_pattern =~ / /g; #  how many spaces do we have in our time pattern?
my $dateFieldsCount = @dateFields; # count the number spaces in the date format

if ($debug) { 
$verbose = 1; # if we debug, we want to have all information
print "Interval: $interval equals " . ($interval/1440) . " Fraction of days.\n";
}


$logfile=~m/^.+\//; 
$DIR=$&; # greedy matching from theline above

@files = find(\&process, $DIR);
sub process {

### note the following is done for each file that is found and matches the name and date criteria
	if ($File::Find::name =~ m/$logfile/ && (-T)) { # match only files that are ASCII files (-T) and that contain the file name
		$validFileNames += 1;	
		if ($debug) {  print "Found: $File::Find::name has age " .((-M)*1440-(360)) ." (minutes) \n"; }

		# -M returns the last change date of the file in fraction of days. e.g. 24 ago -> 1, 6 hours ago -> 0.25
		if ((-M)*1440-(360) < $interval) 
		{  # match only files whose last change (-M) is within the change interval
										# perldoc defines -M : Script start time minus file modification time, in days.

		$LOGS = File::ReadBackwards->new($File::Find::name) or
			die "Can't read file: $File::Find::name\n";

		while (defined($line = $LOGS->readline) ) {
			my @fields = split ' ', $line; # split the line into an array, split on ' '(space)
			$dateString = ""; # reset the datestring for each line
			for ($i=0; $i <= $dateFieldsCount; $i++) {
				$dateString .= $fields[$time_position + $i] . " "; # concatenate all date strings into one parseable string
			}
			$dateString =~ s/^\s+|\s+$//g ; # remove both leading and tailing whitespace - perl 6 will have a trim() function, until then - regex !
			$dateString =~ s/<|>|\]|\[//g ; # remove brackets
			$dateString =~ s/,+$|\.+$//g;
			#$dateString =~ s/,\d+$|\.\d+$//g;


			if ($debug) {print "Datestring: $dateString \n";}# this is only needed if you are unsure which strings of the array are part of your datestring
			eval{
			my $dt =  Time::Piece->strptime($dateString, $time_pattern); # parse string into Time::Piece object
			my $dt_tzadjusted = ($dt - $now->tzoffset); # TIME::PIECE assumes the parsed dates will be UTC, we need to adjust to the local tz offset
			
			# some date formats don't have the year information e.g. Dec 31 15:50:57 -> the year would automatically be parsed to 1970, 
			# which is probably never correct. We will correct this to this or last year
			if ($dt->year eq 1970) { 
				$dt = $dt->add_years($now->year - 1970); # We cannot set the year directly. So we add the number of years that have passed since 1970. 
				$dt_tzadjusted = ($dt - $now->tzoffset);
				# NOTE: If $now is January 1st and we're looking at log files from the end of last year, we will add too many years
				# hence if the date is now in the future, we subtract one year again.
				if ($dt_tzadjusted > $now) { 
					$dt = $dt->add_years(-1);
					$dt_tzadjusted = ($dt - $now->tzoffset);
					#print "T: $dt_tzadjusted \n";
				}
			}
			#print "T: $dt_tzadjusted \n";

			if ($dt_tzadjusted > $oldestDate) { # is the date bigger=>newer than the oldest date we want to look at?
				#if ($debug) { print "line: $line \n";}
				#print "line: $line \n";
				if ($line =~ m/$pattern_timeout/){ # if the line contains the regex pattern
					$table{$1}[0]++;
					$table{'ID_TIMEOUT'} = $table{'ID_TIMEOUT'}.$1."-".$5.':'.$2.',';
					if ($debug) { print "Timeout: $1 -- $2 -- $3 -- $4 -- $5\n";}				
					}
				if ($line =~ m/$pattern_failed/){ # if the line contains the regex pattern
					$table{$1}[2]++;
					$table{'ID_FAILED'} = $table{'ID_FAILED'}.$1."-".$5.':'.$2.',';
					$table{'TIME_PROCESS'} += $3;
					if ($debug) { print "Failed: $1 -- $2 -- $3 -- $4 -- $5\n";}	
				}				
				if ($line =~ m/$pattern_successed/){ # if the line contains the regex pattern
					$table{$1}[1]++;
					$table{'TIME_PROCESS'} += $3;
					if ($debug) { print "Successed: $1 -- $2 -- $3 -- $4 -- $5\n";}	
				}
			}
			else{
				last; #if the date is older than the oldest we still care about, leave this loop -> go to the next file if available
			}
		} or next;
		}
		close(LOGS);
		}
	}
}## the find sub process ends here

	if ($validFileNames == 0) {
		print "Khong tim thay file: \"$logfile\"";
		exit 0; }	
		
	my $avg_time_process = 0;
	my $trans_num = $table{'SEARCH'}[1] + $table{'GET_TOKEN'}[1] + $table{'GET_SEAT'}[1] + $table{'BOOK'}[1] + $table{'PAYMENT'}[1] + $table{'GET_SEAT'}[2]+ $table{'SEARCH'}[2] + $table{'GET_TOKEN'}[2]+ $table{'BOOK'}[2] + $table{'PAYMENT'}[2];
	if ($trans_num > 0) {
		$avg_time_process = $table{'TIME_PROCESS'}/$trans_num;
	}
		
	my $txt_request = '';	
	if (($table{'SEARCH'}[0] + $table{'GET_TOKEN'}[0] + $table{'GET_SEAT'}[0] + $table{'BOOK'}[0] + $table{'PAYMENT'}[0]) > ($critical + 0)) {
		if ($table{'SEARCH'}[0] > 0) { $txt_request = $table{'SEARCH'}[0].' yeu cau Tim Ve ';}
		if ($table{'GET_TOKEN'}[0] > 0) { $txt_request = $table{'SEARCH'}[0].' yeu cau Tim Ve va '.$table{'GET_TOKEN'}[0].' Dat Ve ';}
		if ($table{'GET_SEAT'}[0] > 0) { $txt_request = $table{'SEARCH'}[0].' yeu cau Tim Ve, '.$table{'GET_TOKEN'}[0].' Dat Ve va '.$table{'GET_SEAT'}[0].' Dat Ghe Ngoi ';}
		if ($table{'BOOK'}[0] > 0) { $txt_request = $table{'SEARCH'}[0].' yeu cau Tim Ve, '.$table{'GET_TOKEN'}[0].' Dat Ve, '.$table{'GET_SEAT'}[0].' Dat Ghe Ngoi va '.$table{'BOOK'}[0].' Tao Don Hang ';}
		if ($table{'PAYMENT'}[0] > 0) { $txt_request = $table{'SEARCH'}[0].' yeu cau Tim Ve, '.$table{'GET_TOKEN'}[0].' Dat Ve, '.$table{'GET_SEAT'}[0].' Dat Ghe Ngoi, '.$table{'BOOK'}[0].' Tao Don Hang va '.$table{'PAYMENT'}[0].' Xac Nhan Dat Ve ';}
			
		
		
		print "Co ".$txt_request." bi Timeout trong ".$interval." phut qua, ID_Timeout(".$table{'ID_TIMEOUT'}.")";
		
		print "|TimVe_Timeout=".$table{'SEARCH'}[0];
		print " TimVe_Successed=".$table{'SEARCH'}[1];
		print " TimVe_Failed=".($table{'SEARCH'}[2]+$table{'SEARCH'}[0]);
		print " DatVe_Timeout=".$table{'GET_TOKEN'}[0];
		print " DatVe_Successed=".$table{'GET_TOKEN'}[1];
		print " DatVe_Failed=".($table{'GET_TOKEN'}[2]+$table{'GET_TOKEN'}[0]);
		print " DatGhe_Timeout=".$table{'GET_SEAT'}[0];
		print " DatGhe_Successed=".$table{'GET_SEAT'}[1];
		print " DatGhe_Failed=".($table{'GET_SEAT'}[2]+$table{'GET_SEAT'}[0]);
		print " TaoDon_Timeout=".$table{'BOOK'}[0];
		print " TaoDon_Successed=".$table{'BOOK'}[1];
		print " TaoDon_Failed=".($table{'BOOK'}[2]+$table{'GET_SEAT'}[0]);
		print " XacNhan_Timeout=".$table{'PAYMENT'}[0];
		print " XacNhan_Successed=".$table{'PAYMENT'}[1];
		print " XacNhan_Failed=".($table{'PAYMENT'}[2]+$table{'PAYMENT'}[0]);
		printf " Avg_Time_Process=%.1fs",$avg_time_process;
		
		exit 2;
	}	
	if (($table{'SEARCH'}[2] + $table{'GET_TOKEN'}[2] + $table{'GET_SEAT'}[2] + $table{'BOOK'}[2] + $table{'PAYMENT'}[2]) > ($warning + 0)) {
			if ($table{'SEARCH'}[2] > 0) { $txt_request = $table{'SEARCH'}[2].' yeu cau Tim Ve ';}
			if ($table{'GET_TOKEN'}[2] > 0) { $txt_request = $table{'SEARCH'}[2].' yeu cau Tim Ve va '.$table{'GET_TOKEN'}[2].' Dat Ve ';}
			if ($table{'GET_SEAT'}[2] > 0) { $txt_request = $table{'SEARCH'}[2].' yeu cau Tim Ve, '.$table{'GET_TOKEN'}[2].' Dat Ve va '.$table{'GET_SEAT'}[2].' Dat Ghe Ngoi ';}
			if ($table{'BOOK'}[2] > 0) { $txt_request = $table{'SEARCH'}[2].' yeu cau Tim Ve, '.$table{'GET_TOKEN'}[2].' Dat Ve, '.$table{'GET_SEAT'}[2].' Dat Ghe Ngoi va '.$table{'BOOK'}[2].' Tao Don Hang ';}
			if ($table{'PAYMENT'}[2] > 0) { $txt_request = $table{'SEARCH'}[2].' yeu cau Tim Ve, '.$table{'GET_TOKEN'}[2].' Dat Ve, '.$table{'GET_SEAT'}[2].' Dat Ghe Ngoi, '.$table{'BOOK'}[2].' Tao Don Hang, '.$table{'PAYMENT'}[2].' Xac Nhan Dat Ve ';}
			
		
		
		print "Co ".$txt_request." bi Failed trong ".$interval." phut qua, ID_Failed(".$table{'ID_FAILED'}.")";
		
		print "|TimVe_Timeout=".$table{'SEARCH'}[0];
		print " TimVe_Successed=".$table{'SEARCH'}[1];
		print " TimVe_Failed=".($table{'SEARCH'}[2]+$table{'SEARCH'}[0]);
		print " DatVe_Timeout=".$table{'GET_TOKEN'}[0];
		print " DatVe_Successed=".$table{'GET_TOKEN'}[1];
		print " DatVe_Failed=".($table{'GET_TOKEN'}[2]+$table{'GET_TOKEN'}[0]);
		print " DatGhe_Timeout=".$table{'GET_SEAT'}[0];
		print " DatGhe_Successed=".$table{'GET_SEAT'}[1];
		print " DatGhe_Failed=".($table{'GET_SEAT'}[2]+$table{'GET_SEAT'}[0]);
		print " TaoDon_Timeout=".$table{'BOOK'}[0];
		print " TaoDon_Successed=".$table{'BOOK'}[1];
		print " TaoDon_Failed=".($table{'BOOK'}[2]+$table{'GET_SEAT'}[0]);
		print " XacNhan_Timeout=".$table{'PAYMENT'}[0];
		print " XacNhan_Successed=".$table{'PAYMENT'}[1];
		print " XacNhan_Failed=".($table{'PAYMENT'}[2]+$table{'PAYMENT'}[0]);
		printf " Avg_Time_Process=%.1fs",$avg_time_process;
	
		exit 1; }	

	print "Co ".($table{'SEARCH'}[1] + $table{'GET_TOKEN'}[1]+ $table{'GET_SEAT'}[1] + $table{'BOOK'}[1] + $table{'PAYMENT'}[1])."/".($table{'SEARCH'}[0] + $table{'GET_TOKEN'}[0]+ $table{'GET_SEAT'}[0] + $table{'BOOK'}[0] + $table{'PAYMENT'}[0]+$table{'SEARCH'}[2] + $table{'GET_TOKEN'}[2]+ $table{'GET_SEAT'}[2] + $table{'BOOK'}[2] + $table{'PAYMENT'}[2])." giao dich Successed/Failed trong ".$interval." phut qua";
	print "|TimVe_Timeout=".$table{'SEARCH'}[0];
		print " TimVe_Successed=".$table{'SEARCH'}[1];
		print " TimVe_Failed=".($table{'SEARCH'}[2]+$table{'SEARCH'}[0]);
		print " DatVe_Timeout=".$table{'GET_TOKEN'}[0];
		print " DatVe_Successed=".$table{'GET_TOKEN'}[1];
		print " DatVe_Failed=".($table{'GET_TOKEN'}[2]+$table{'GET_TOKEN'}[0]);
		print " DatGhe_Timeout=".$table{'GET_SEAT'}[0];
		print " DatGhe_Successed=".$table{'GET_SEAT'}[1];
		print " DatGhe_Failed=".($table{'GET_SEAT'}[2]+$table{'GET_SEAT'}[0]);
		print " TaoDon_Timeout=".$table{'BOOK'}[0];
		print " TaoDon_Successed=".$table{'BOOK'}[1];
		print " TaoDon_Failed=".($table{'BOOK'}[2]+$table{'GET_SEAT'}[0]);
		print " XacNhan_Timeout=".$table{'PAYMENT'}[0];
		print " XacNhan_Successed=".$table{'PAYMENT'}[1];
		print " XacNhan_Failed=".($table{'PAYMENT'}[2]+$table{'PAYMENT'}[0]);
		printf " Avg_Time_Process=%.1fs",$avg_time_process;
	
		
    exit 0;

