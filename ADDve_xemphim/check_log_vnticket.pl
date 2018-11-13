#!/usr/bin/perl

use File::ReadBackwards; # EPEL RPM: perl-File-ReadBackwards.noarch 
use Getopt::Long;
use Time::Piece; # RHEL package: perl-Time-Piece
use File::Find;


my %table;
#(hang,request,timeout,successed,failed)
$table{'VN'}->{'SEARCH_FLIGHT'} = [0,0,0];
$table{'VN'}->{'RESERVATION'} = [0,0,0];
$table{'VJ'}->{'SEARCH_FLIGHT'} = [0,0,0];
$table{'VJ'}->{'RESERVATION'} = [0,0,0];
$table{'JQ'}->{'SEARCH_FLIGHT'} = [0,0,0];
$table{'JQ'}->{'RESERVATION'} = [0,0,0];

$table{'ALL'}->{'SEARCH_FLIGHT'} = [0,0,0];
$table{'ALL'}->{'RESERVATION'} = [0,0,0];

$table{'ALL'}->{'ID_TIMEOUT'} = '';
$table{'ALL'}->{'ID_FAILED'} = '';
$table{'ALL'}->{'TIME_PROCESS'} = 0;

	
$time_pattern = '%Y-%m-%d %H:%M:%S';
$warning = 1;
$critical = 1;
$time_position = 0;

# 2017-07-17 09:05:20 Hang:VN Request:SEARCH_FLIGHT Response:00 time_process:9 Query_Id:17407
#Hang:(VN|VJ|JQ).Request:(SEARCH_FLIGHT|RESERVATION).Response:00.time_process:(\d+).Query_Id:(\d+)
$pattern_timeout = "Hang:(VN|VJ|JQ) Request:(SEARCH_FLIGHT|RESERVATION) Response:(08|99|03) time_process:(\\d+) Query_Id:(\\d+)";
$pattern_successed = "Hang:(VN|VJ|JQ) Request:(SEARCH_FLIGHT|RESERVATION) Response:(00) time_process:(\\d+) Query_Id:(\\d+)";
$pattern_failed = "Hang:(VN|VJ|JQ) Request:(SEARCH_FLIGHT|RESERVATION) Response:(0[1-9]|[1-9][0-9]) time_process:(\\d+) Query_Id:(\\d+)";

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
			$dateString =~ s/,\d+$|\.\d+$//g;


			if ($debug) { print "Datestring: $dateString \n";} # this is only needed if you are unsure which strings of the array are part of your datestring
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
				}
			}

			if ($dt_tzadjusted > $oldestDate) { # is the date bigger=>newer than the oldest date we want to look at?
				#if ($debug) { print "line: $line \n";}
				if ($line =~ m/$pattern_timeout/){ # if the line contains the regex pattern
					$table{$1}->{$2}[0]++;
					$table{'ALL'}->{$2}[0]++;
					$table{'ALL'}->{'ID_TIMEOUT'} = $table{'ALL'}->{'ID_TIMEOUT'}.$1."-".$5.':'.$3.',';
					if ($debug) { print "Timeout: $1 -- $2 -- $3 -- $4 -- $5\n";}					
					}
				if ($line =~ m/$pattern_failed/){ # if the line contains the regex pattern
					$table{$1}->{$2}[2]++;
					$table{'ALL'}->{$2}[2]++;
					$table{'ALL'}->{'ID_FAILED'} = $table{'ALL'}->{'ID_FAILED'}.$1."-".$5.':'.$3.',';
					$table{'ALL'}->{'TIME_PROCESS'} += $4;
					if ($debug) { print "Failed: $1 -- $2 -- $3 -- $4 -- $5\n";}	
				}				
				if ($line =~ m/$pattern_successed/){ # if the line contains the regex pattern
					$table{$1}->{$2}[1]++;
					$table{'ALL'}->{$2}[1]++;
					$table{'ALL'}->{'TIME_PROCESS'} += $4;
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
	my $trans_num = $table{'ALL'}->{'SEARCH_FLIGHT'}[1] + $table{'ALL'}->{'RESERVATION'}[1]+$table{'ALL'}->{'SEARCH_FLIGHT'}[2] + $table{'ALL'}->{'RESERVATION'}[2];
	if ($trans_num > 0) {
		$avg_time_process = $table{'ALL'}->{'TIME_PROCESS'}/$trans_num;
	}
		
	my $txt_request = '';	
	if (($table{'ALL'}->{'SEARCH_FLIGHT'}[0] + $table{'ALL'}->{'RESERVATION'}[0]) > ($critical + 0)) {
		if ($table{'ALL'}->{'RESERVATION'}[0] > 0 && $table{'ALL'}->{'SEARCH_FLIGHT'}[0] > 0){ $txt_request = $table{'ALL'}->{'SEARCH_FLIGHT'}[0].' yeu cau Tim Ve va '.$table{'ALL'}->{'RESERVATION'}[0].' giao dich Dat Ve';}
		else {
			if ($table{'ALL'}->{'SEARCH_FLIGHT'}[0] > 0){ $txt_request = $table{'ALL'}->{'SEARCH_FLIGHT'}[0].' yeu cau Tim Ve';}
			elsif ($table{'ALL'}->{'RESERVATION'}[0] > 0){ $txt_request = $table{'ALL'}->{'RESERVATION'}[0].' giao dich Dat Ve';}
			}
		
		
		print "Co ".$txt_request." bi Timeout trong ".$interval." phut qua, ID_Timeout(".$table{'ALL'}->{'ID_TIMEOUT'}.")";
		
		print "|TimVe_Timeout=".$table{'ALL'}->{'SEARCH_FLIGHT'}[0];
		print " TimVe_Successed=".$table{'ALL'}->{'SEARCH_FLIGHT'}[1];
		print " TimVe_Failed=".($table{'ALL'}->{'SEARCH_FLIGHT'}[2]+$table{'ALL'}->{'SEARCH_FLIGHT'}[0]);
		print " DatVe_Timeout=".$table{'ALL'}->{'RESERVATION'}[0];
		print " DatVe_Successed=".$table{'ALL'}->{'RESERVATION'}[1];
		print " DatVe_Failed=".($table{'ALL'}->{'RESERVATION'}[2]+$table{'ALL'}->{'RESERVATION'}[0]);
		printf " Avg_Time_Process=%.1fs",$avg_time_process;
		
		print " VN_TimVe_Timeout=".$table{'VN'}->{'SEARCH_FLIGHT'}[0];
		print " VN_TimVe_Successed=".$table{'VN'}->{'SEARCH_FLIGHT'}[1];
		print " VN_TimVe_Failed=".$table{'VN'}->{'SEARCH_FLIGHT'}[2];
		print " VJ_TimVe_Timeout=".$table{'VJ'}->{'SEARCH_FLIGHT'}[0];
		print " VJ_TimVe_Successed=".$table{'VJ'}->{'SEARCH_FLIGHT'}[1];
		print " VJ_TimVe_Failed=".$table{'VJ'}->{'SEARCH_FLIGHT'}[2];
		print " JQ_TimVe_Timeout=".$table{'JQ'}->{'SEARCH_FLIGHT'}[0];
		print " JQ_TimVe_Successed=".$table{'JQ'}->{'SEARCH_FLIGHT'}[1];
		print " JQ_TimVe_Failed=".$table{'JQ'}->{'SEARCH_FLIGHT'}[2];
		
		print " VN_DatVe_Timeout=".$table{'VN'}->{'RESERVATION'}[0];
		print " VN_DatVe_Successed=".$table{'VN'}->{'RESERVATION'}[1];
		print " VN_DatVe_Failed=".$table{'VN'}->{'RESERVATION'}[2];
		print " VJ_DatVe_Timeout=".$table{'VJ'}->{'RESERVATION'}[0];
		print " VJ_DatVe_Successed=".$table{'VJ'}->{'RESERVATION'}[1];
		print " VJ_DatVe_Failed=".$table{'VJ'}->{'RESERVATION'}[2];
		print " JQ_DatVe_Timeout=".$table{'JQ'}->{'RESERVATION'}[0];
		print " JQ_DatVe_Successed=".$table{'JQ'}->{'RESERVATION'}[1];
		print " JQ_DatVe_Failed=".$table{'JQ'}->{'RESERVATION'}[2];
		
		exit 2;
	}	
	if (($table{'ALL'}->{'SEARCH_FLIGHT'}[2] + $table{'ALL'}->{'RESERVATION'}[2])  >= ($warning + 0)) {

		if ($table{'ALL'}->{'RESERVATION'}[2] > 0 && $table{'ALL'}->{'SEARCH_FLIGHT'}[2] > 0){ $txt_request = $table{'ALL'}->{'SEARCH_FLIGHT'}[2].' yeu cau Tim Ve va '.$table{'ALL'}->{'RESERVATION'}[2].' giao dich Dat Ve';}
		else {
			if ($table{'ALL'}->{'SEARCH_FLIGHT'}[2] > 0){ $txt_request = $table{'ALL'}->{'SEARCH_FLIGHT'}[2].' yeu cau Tim Ve';}
			elsif ($table{'ALL'}->{'RESERVATION'}[2] > 0){ $txt_request = $table{'ALL'}->{'RESERVATION'}[2].' giao dich Dat Ve';}
			}
		
		
		print "Co ".$txt_request." bi Failed trong ".$interval." phut qua, ID_Failed(".$table{'ALL'}->{'ID_FAILED'}.")";
		
		print "|TimVe_Timeout=".$table{'ALL'}->{'SEARCH_FLIGHT'}[0];
		print " TimVe_Successed=".$table{'ALL'}->{'SEARCH_FLIGHT'}[1];
		print " TimVe_Failed=".($table{'ALL'}->{'SEARCH_FLIGHT'}[2]+$table{'ALL'}->{'SEARCH_FLIGHT'}[0]);
		print " DatVe_Timeout=".$table{'ALL'}->{'RESERVATION'}[0];
		print " DatVe_Successed=".$table{'ALL'}->{'RESERVATION'}[1];
		print " DatVe_Failed=".($table{'ALL'}->{'RESERVATION'}[2]+$table{'ALL'}->{'RESERVATION'}[0]);
		printf " Avg_Time_Process=%.1fs",$avg_time_process;
		
		print " VN_TimVe_Timeout=".$table{'VN'}->{'SEARCH_FLIGHT'}[0];
		print " VN_TimVe_Successed=".$table{'VN'}->{'SEARCH_FLIGHT'}[1];
		print " VN_TimVe_Failed=".$table{'VN'}->{'SEARCH_FLIGHT'}[2];
		print " VJ_TimVe_Timeout=".$table{'VJ'}->{'SEARCH_FLIGHT'}[0];
		print " VJ_TimVe_Successed=".$table{'VJ'}->{'SEARCH_FLIGHT'}[1];
		print " VJ_TimVe_Failed=".$table{'VJ'}->{'SEARCH_FLIGHT'}[2];
		print " JQ_TimVe_Timeout=".$table{'JQ'}->{'SEARCH_FLIGHT'}[0];
		print " JQ_TimVe_Successed=".$table{'JQ'}->{'SEARCH_FLIGHT'}[1];
		print " JQ_TimVe_Failed=".$table{'JQ'}->{'SEARCH_FLIGHT'}[2];
		
		print " VN_DatVe_Timeout=".$table{'VN'}->{'RESERVATION'}[0];
		print " VN_DatVe_Successed=".$table{'VN'}->{'RESERVATION'}[1];
		print " VN_DatVe_Failed=".$table{'VN'}->{'RESERVATION'}[2];
		print " VJ_DatVe_Timeout=".$table{'VJ'}->{'RESERVATION'}[0];
		print " VJ_DatVe_Successed=".$table{'VJ'}->{'RESERVATION'}[1];
		print " VJ_DatVe_Failed=".$table{'VJ'}->{'RESERVATION'}[2];
		print " JQ_DatVe_Timeout=".$table{'JQ'}->{'RESERVATION'}[0];
		print " JQ_DatVe_Successed=".$table{'JQ'}->{'RESERVATION'}[1];
		print " JQ_DatVe_Failed=".$table{'JQ'}->{'RESERVATION'}[2];
		
		exit 1; }	

	print "Co ".($table{'ALL'}->{'SEARCH_FLIGHT'}[1] + $table{'ALL'}->{'RESERVATION'}[1])."/".($table{'ALL'}->{'SEARCH_FLIGHT'}[0] + $table{'ALL'}->{'RESERVATION'}[0]+$table{'ALL'}->{'SEARCH_FLIGHT'}[2] + $table{'ALL'}->{'RESERVATION'}[2])." giao dich Successed/Failed trong ".$interval." phut qua";
	print "|TimVe_Timeout=".$table{'ALL'}->{'SEARCH_FLIGHT'}[0];
	print " TimVe_Successed=".$table{'ALL'}->{'SEARCH_FLIGHT'}[1];
	print " TimVe_Failed=".($table{'ALL'}->{'SEARCH_FLIGHT'}[2]+$table{'ALL'}->{'SEARCH_FLIGHT'}[0]);
	print " DatVe_Timeout=".$table{'ALL'}->{'RESERVATION'}[0];
	print " DatVe_Successed=".$table{'ALL'}->{'RESERVATION'}[1];
	print " DatVe_Failed=".($table{'ALL'}->{'RESERVATION'}[2]+$table{'ALL'}->{'RESERVATION'}[0]);
	printf " Avg_Time_Process=%.1fs",$avg_time_process;
	
	print " VN_TimVe_Timeout=".$table{'VN'}->{'SEARCH_FLIGHT'}[0];
	print " VN_TimVe_Successed=".$table{'VN'}->{'SEARCH_FLIGHT'}[1];
	print " VN_TimVe_Failed=".$table{'VN'}->{'SEARCH_FLIGHT'}[2];
	print " VJ_TimVe_Timeout=".$table{'VJ'}->{'SEARCH_FLIGHT'}[0];
	print " VJ_TimVe_Successed=".$table{'VJ'}->{'SEARCH_FLIGHT'}[1];
	print " VJ_TimVe_Failed=".$table{'VJ'}->{'SEARCH_FLIGHT'}[2];
	print " JQ_TimVe_Timeout=".$table{'JQ'}->{'SEARCH_FLIGHT'}[0];
	print " JQ_TimVe_Successed=".$table{'JQ'}->{'SEARCH_FLIGHT'}[1];
	print " JQ_TimVe_Failed=".$table{'JQ'}->{'SEARCH_FLIGHT'}[2];
	
	print " VN_DatVe_Timeout=".$table{'VN'}->{'RESERVATION'}[0];
	print " VN_DatVe_Successed=".$table{'VN'}->{'RESERVATION'}[1];
	print " VN_DatVe_Failed=".$table{'VN'}->{'RESERVATION'}[2];
	print " VJ_DatVe_Timeout=".$table{'VJ'}->{'RESERVATION'}[0];
	print " VJ_DatVe_Successed=".$table{'VJ'}->{'RESERVATION'}[1];
	print " VJ_DatVe_Failed=".$table{'VJ'}->{'RESERVATION'}[2];
	print " JQ_DatVe_Timeout=".$table{'JQ'}->{'RESERVATION'}[0];
	print " JQ_DatVe_Successed=".$table{'JQ'}->{'RESERVATION'}[1];
	print " JQ_DatVe_Failed=".$table{'JQ'}->{'RESERVATION'}[2];
		
    exit 0;

