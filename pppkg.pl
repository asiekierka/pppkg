#!/usr/bin/perl

use Data::Dumper;
use warnings;

# Builtin
use File::Temp qw(tempfile tempdir);
use Archive::Tar;
use File::Copy;
use File::Path qw(rmtree);
# Additional
use JSON;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);

my $package_ext = ".ppk";
my $prefix = "/";
my $db;

sub die_error {
	my $text = shift;
	my $code = shift;
	if($code < 1) { $code=1; }
	print "[ERROR] " . $text . "\n";
	exit($code);
}

sub cmd_help {
	print "\n[ Portable(-ish) Perl PacKaGist 0.1 ]\n";
	print "Options:\n";
	print "\t-h\t\tHelp\n\t-i [pkg" . $package_ext . "]\tInstall package file\n";
	print "\t-r [pkg-name]\tRemove package (UNFINISHED)\n";
	print "\t-v\t\tVerbose\n\t-f\t\tForce\n\t\-P [prefix]\tPrefix folder\n";
	print "\t-C\t\tPrefer compiling.\n\t-l\t\tList installed packages.";
	print "\n";
}

sub hardlink_copy {
	my ($src, $dest, $verbose, $force) = @_;
	# Screw the Perl ways! Bash on it!
	open(FILELIST, ">","filelist")
		or die_error("Cannot create filelist!",8);
	chdir $src;
	my @files = `find *`;
	foreach $file (@files) {
		print FILELIST $file;
		$file=~s/\n//g;
		if($verbose>=2) { print $dest.$file . "\n"; }
		if(-f $src.$file) {
			$errcode = system("ln ".$src.$file." ".$dest.$file);
			unless($errcode==0) { if($force<1) { print "[WARNING] Error while hardlinking " . $file . "!\n"; } }
		} elsif(-d $src.$file) {
			unless(-d ($dest.$file)) {mkdir ($dest.$file);}
		}
	}
	close(FILELIST);
	return @files;
}
sub readJSON {
	my $filename = shift;
	open(FILE,"<",$filename)
		or die_error("Could not read JSON file!",5);
	my $fh_text = "";
	foreach $line (<FILE>) { $fh_text .= $line; };
	close(FILE);
	return decode_json($fh_text);
}
sub writeJSON {
	my ($filename,$data) = @_;
	open(FILE,">",$filename)
		or die_error("Could not write JSON file!",5);
	print FILE encode_json($data);
	close(FILE);
}
sub db_addpkg {
	my ($info, @filelist) = @_;
	$db->{packages}->{($info->{meta}->{name})} = $info;
	# TODO: Filelist.
}
sub db_removepkg {
	my ($name) = @_;
	delete $db->{packages}->{$name};
}
sub db_update {
	writeJSON($prefix."var/pkg/db.json",$db);
}
sub cmd_list {
	my ($verbose) = @_;
	my $i = 0;
	for my $key (sort keys %{$db->{packages}})
	{
		my $entry = $db->{packages}->{$key};
		print $entry->{meta}->{name} . "-" . $entry->{meta}->{version} . " [". $entry->{meta}->{description} ."]\n";
		$i++;
	}
	print $i . " packages total.\n";
}
sub cmd_uninstall {
	my ($package, $verbose, $force) = @_;
	my $pkgdir = $prefix."var/pkg/files/".$package;
	# Abuse the fact that the filelist is generated during the hardlinking.
	unless(-e $pkgdir."/filelist"){ die_error("Package " . $package . " isn't installed!"); }
	print "Removing package " . $package . "...\n";
	if($verbose>=2) { print "Reading filelist...\n"; }
	open(FILELIST, "<", $pkgdir."/filelist")
		or die_error("Cannot open filelist!",5);
	my @files = <FILELIST>;
	close(FILELIST);
	my $fullpath = "";
	my @dirs = ();
	foreach $file (@files) {
		$file=~s/\n//g;
		$fullpath = $prefix.$file;
		if(-e $fullpath) {
			if($verbose>=2) { print "Removing " . $fullpath . "\n"; }
			if(-f $fullpath) {
				unlink($fullpath)
					or die_error("COULDN'T UNLINK FILE! THIS MAY MEAN A BROKEN SYSTEM",9);
			} elsif(-d $fullpath) {
				push(@dirs,$fullpath);
			}
		}
	}
	# We have to check for empty dirs. You know.
	foreach $dir (@dirs) {
		unless (scalar <$dir/*>) {
			if($verbose>=2) { print "Removing " . $dir . "\n"; }
			rmdir($dir);
		}
	}
	if($verbose>=1) { print "Removing package...\n"; }
	rmtree($pkgdir)
		or die_error("Couldn't remove package!",10);
	db_removepkg($package);
	db_update();
	print "Package ".$package." uninstalled successfully!\n";
}
sub cmd_install {
	my ($package, $verbose, $force, $compile) = @_;
	print "Installing package " . $package . "...\n";
	unless(-e $package) { $package=$package.$package_ext;
		unless(-e $package) { die_error("File doesn't exist",3); }
	}
	if($verbose>=2) { print "Creating tempdir...\n"; }
	$tempdir = tempdir("/tmp/pkgist-XXXXXXXX", CLEANUP => 0);	
	if($verbose>=1) { print "Unpacking package...\n"; }
	$temparch = $tempdir . "/pkg.tar";
	bunzip2 $package => $temparch or die_error("[BZIP2] ".$Bunzip2Error,4);
	chdir $tempdir;
	Archive::Tar->extract_archive("pkg.tar") or die_error("[TAR] An error!",4);
	unlink("pkg.tar");
	print "Reading package...\n";
	my $package_info = readJSON("info.json");
	my $pkgname = $package_info->{meta}->{name};
	my $pkgdir = $prefix."var/pkg/files/".$pkgname;
	my $rootdir = $pkgdir."/root";
	if(-d $rootdir){ die_error("The package is already installed! Uninstall it first.",8); }
	if(!(-d "root") or ($compile==1 and ($package_info->{package}->{script} ne "")))
	{
		print "Compiling...\n";
		if(-d "root") { rmtree("root") or die_error("Couldn't remove rootdir!",5); }
		mkdir "root" or die_error("Couldn't create directory",5);
		system(("./" . $package_info->{package}->{script}, $tempdir . "/root/")) == 0
			or die_error("Compilation failed: $?",6);
	}
	if($verbose>=1) { print "Moving package...\n"; }
	unless(-d ($pkgdir)){mkdir ($pkgdir);}
	# Should be more portable, really. But who'll want to install this on Windows?
	# Is that even possible?
	system("mv ".$tempdir."/* ".$pkgdir);
	unless(-d $rootdir){ die_error("Moving failed: $?",7); }
	print "Installing files...\n";
	chdir $pkgdir;
	my @filelist = hardlink_copy($rootdir."/", $prefix, $verbose, $force);
	db_addpkg($package_info,@filelist);
	db_update();
	print "Package " . $pkgname . " installed!\n";
	exit(0);
}

my $argv_len = @ARGV;
my $args = 0;
my $command = "nope";
my $package = "";
my $verbose = 0;
my $force = 0;
my $compile = 0;

# TODO: Make a better argparser.
for(;$args<$argv_len;$args++)
{
	if($ARGV[$args] eq "-h") {
		cmd_help();
		exit(0);
	} elsif($ARGV[$args] eq "-i") {
		if($args<($argv_len-1)) {
			$command = "install";
			$package = $ARGV[$args+1];
			$args++;
		} else { die_error("Package not specified.",2); }
	} elsif($ARGV[$args] eq "-r") {
		if($args<($argv_len-1)) {
			$command = "remove";
			$package = $ARGV[$args+1];
			$args++;
		} else { die_error("Package not specified.",2); }
	} elsif($ARGV[$args] eq "-P") {
		if($args<($argv_len-1)) {
			$prefix = $ARGV[$args+1];
			$args++;
		} else { die_error("Prefix not specified.",2); }
	} elsif($ARGV[$args] eq "-l") {
		$command = "list";
	} elsif($ARGV[$args] eq "-v") {
		$verbose+=1;
	} elsif($ARGV[$args] eq "-f") {
		$force=1;
	} elsif($ARGV[$args] eq "-C") {
		$compile=1;
	} elsif($ARGV[$args] eq "chimicherry") {
		print "Cherrychanga!\n";
		exit(0);
	}
}

# Make directories that may be needed.
unless(-d ($prefix . "var")){mkdir ($prefix."var");}
unless(-d ($prefix . "var/pkg")){mkdir ($prefix."var/pkg");}
unless(-d ($prefix . "var/pkg/files")){mkdir ($prefix."var/pkg/files");}
# Create empty DB if needed.
unless(-f ($prefix . "var/pkg/db.json")){
	my $db = {};
	$db->{packages} = {};
	$db->{providers} = {};
	$db->{files} = {};
	writeJSON($prefix."var/pkg/db.json",$db);
}
# Commands.
if($command ne "nope")
{
	print "Loading database...";
	$db = readJSON($prefix . "var/pkg/db.json");
	print " complete\n";	
}
if($command eq "install") { cmd_install($package,$verbose,$force,$compile); }
elsif($command eq "remove") { cmd_uninstall($package,$verbose,$force); }
elsif($command eq "list") { cmd_list($verbose); }
else { die_error("No command specified.\nUse -h for help."); }
