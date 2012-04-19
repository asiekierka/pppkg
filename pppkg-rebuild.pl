#!/bin/perl

use warnings;

# DEPENDENCIES
# Builtin
use IO::Compress::Gzip;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
# Additional
use JSON;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);

my $db = {};
$db->{packages} = {};
$db->{providers} = {};
$db->{files} = {};
my $mtime = 0;

# VARIABLES
# SUBROUTINES
sub die_error {
	my $text = shift;
	my $code = shift;
	if(!defined($code) or $code < 1) { $code=1; }
	print "[ERROR] " . $text . "\n";
	chdir("/");
	exit($code);
}
sub hardlink_copy {
	my ($src, $dest) = @_;
	# Screw the Perl ways! Bash on it!
	open(FILELIST, ">","filelist")
		or die_error("Cannot create filelist!",8);
	chdir $src;
	my @files = `find *`;
	foreach $file (@files) {
		print FILELIST $file;
		$file=~s/\n//g;
		#if(-f $dest.$file) { unlink $dest.$file; }
		#if(-l $src.$file) {
		#	unless(-e ($dest.$file)) { symlink(readlink($src.$file),$dest.$file); }
		#}
		#elsif(-f $src.$file) {
		#	$errcode = system("ln ".$src.$file." ".$dest.$file);
		#	unless($errcode==0) { print "[WARNING] Error while hardlinking " . $file . "!\n"; }
		#} elsif(-d $src.$file) {
		#	unless(-d ($dest.$file)) {mkdir ($dest.$file);}
		#}
	}
	close(FILELIST);
	return @files;
}
sub readJSON {
	my $filename = shift;
	my $f = open(FILE, "<", $filename)
		or die_error("Could not read JSON file!",5);
	my $fh_text = "";
	foreach $line (<FILE>) { $fh_text .= $line; };
	close(FILE);
	return decode_json($fh_text);
}
sub writeJSON {
	my ($filename,$data) = @_;
	my $f = open(FILE, ">", $filename)
		or die_error("Could not write JSON file!",5);
	print FILE encode_json($data);
	close(FILE);
}
sub readJSONC {
	my $filename = shift;
	my $f = new IO::Uncompress::Gunzip $filename
		or die_error("Could not read JSON file!",5);
	my $fh_text = "";
	foreach $line (<$f>) { $fh_text .= $line; };
	close($f);
	return decode_json($fh_text);
}
sub writeJSONC {
	my ($filename,$data) = @_;
	my $f = new IO::Compress::Gzip $filename
		or die_error("Could not write JSON file!",5);
	print $f encode_json($data);
	close($f);
}
sub exec_script {
	my $name = shift;
	system($name) == 0
		or die_error("Running script failed: $?",6);
}
# DATABASE
sub db_addpkg {
	my ($info, @filelist) = @_;
	$pkgname =$info->{meta}->{name};
	$db->{packages}->{$pkgname} = $info;
	if($mtime>0) { $db->{packages}->{$pkgname}->{mtime} = $mtime; }
	foreach $file (@filelist) {
		if(defined($db->{files}->{$file})) {
			push($db->{files}->{$file},$pkgname);
		} else {
			$db->{files}->{$file} = [$pkgname];
		}
	}
	my @provides = split(/ /, $info->{meta}->{provides});
	foreach $pr (@provides) {
                if(defined($db->{providers}->{$pr})) {
                        push($db->{providers}->{$pr},$pkgname);
                } else {
                        $db->{providers}->{$pr} = [$pkgname];
                }
	}
}
sub db_removepkg {
	my ($name,@files) = @_;
	my @provides = split(/ /, $db->{packages}->{$name}->{meta}->{provides});
	foreach $pr (@provides) {
                if(defined($db->{providers}->{$pr})) {
			my $arr = $db->{providers}->{$pr};
                	my $arrlen = @{$arr};
                	my $i = 0;
                	for(;$i<$arrlen;$i++) {
                        	if(@{$arr}[$i] eq $name) {
                                	splice($arr,$i,1);
                                	$arrlen--;
                                	last;
                        	}
                	}
	                if($arrlen<1) { delete $db->{providers}->{$pr}; }
		}
	}
	foreach $file (@files) {
		if(defined($db->{files}->{$file})) {
			my $arr = $db->{files}->{$file};
			my $arrlen = @{$arr};
			my $i = 0;
			for(;$i<$arrlen;$i++) {
				if(@{$arr}[$i] eq $name) {
					splice($arr,$i,1);
					$arrlen--;
					last;
				}
			}
			if($arrlen<1) { delete $db->{files}->{$file}; }
			else {
				my $last_app=@{$arr}[$arrlen-1];
				if($last_app ne $name) {
				}
			}
		}
	}
	delete $db->{packages}->{$name};
}
sub db_update {
	writeJSONC("/var/pkg/db.json",$db);
}
# COMMANDS
sub cmd_install {
	my $tempdir = shift;
	print "Installing '".$tempdir."'...";
	chdir $tempdir;
	print "Reading package...\n";
	my $package_info = readJSON("info.json");
	my $pkgname = $package_info->{meta}->{name};
	my $rootdir = $tempdir."/root";
	if(defined($package_info->{package}->{preinstall})) { exec_script("./" . $package_info->{package}->{preinstall}); }
	print "Installing files...\n";
	chdir $tempdir;
	my @filelist = hardlink_copy($rootdir."/", "/");
	if(defined($package_info->{package}->{postinstall})) { chdir $tempdir; exec_script("./" . $package_info->{package}->{postinstall}); }
	db_addpkg($package_info,@filelist);
	print "Package " . $pkgname . " installed!\n";
}

print "Rebuilding\n";
my @packages = `find /var/pkg/files/ -mindepth 1 -maxdepth 1`;
for $pkg (@packages) {
	$pkg=~s/\n//g;
	cmd_install($pkg);
}
print "Saving\n";
db_update();
print "Done! (i think...)\n";
