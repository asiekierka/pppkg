#!/usr/bin/perl

# Builtin
use File::Temp qw(tempfile tempdir);
use Archive::Tar;
use File::Path qw(make_path remove_tree);
use File::Copy;
# Additional
use JSON;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);

my $package_ext = ".ppk";
#my $prefix = "/";
my $prefix = "/home/asiekierka/asieman/fakeroot/";

sub die_error {
	my $text = shift;
	my $code = shift;
	if($code < 1) { $code=1; }
	print "[ERROR] " . $text . "\n";
	exit($code);
}

sub cmd_help {
	print "\n[ Portable Perl PacKaGist 0.1 ]\n";
	print "Options:\n";
	print "\t-h\t\tHelp\n\t-i [pkg" . $package_ext . "]\tInstall package file\n";
	print "\t-v\t\tVerbose\n\t-f\t\tForce\n\t\-P [prefix]\tPrefix folder\n";
	print "\n";
}

sub hardlink_copy {
	my ($src, $dest, $verbose) = @_;
	# Screw the Perl ways! Bash on it!
	open(FILELIST, ">filelist") || die_error("Cannot create filelist!",8);
	chdir $src;
	my @files = `find *`;
	foreach $file (@files) {
		print FILELIST $file;
		$file=~s/\n//g;
		if($verbose>=2) { print $dest.$file . "\n"; }
		system("ln ".$src.$file." ".$dest.$file);
	}
	close(FILELIST);
}
sub cmd_install {
	my ($package, $verbose, $force) = @_;
	print "Installing package " . $package . "...\n";
	unless(-e $package) { die_error("File doesn't exist",3); }
	if($verbose>=2) { print "Creating tempdir...\n"; }
	$tempdir = tempdir("/tmp/pkgist-XXXXXXXX", CLEANUP => 0);	
	if($verbose>=1) { print "Unpacking package...\n"; }
	$temparch = $tempdir . "/pkg.tar";
	bunzip2 $package => $temparch
		or die_error("[BZIP2] ".$Bunzip2Error,4);
	chdir $tempdir;
	Archive::Tar->extract_archive("pkg.tar")
		or die_error("[TAR]",4);
	print "Reading package...\n";
	open(FILE,"<","info.json")
		or die_error("Could not read package!",5);
	my $fh_text = "";
	foreach $line (<FILE>) { $fh_text .= $line; };
	close(FILE);
	my $package_info = decode_json($fh_text);
	my $pkgname = $package_info->{meta}->{name} . "-" . $package_info->{meta}->{version};
	unless(-d "root")
	{
		print "Compiling...\n";
		mkdir "root" or die_error("Couldn't create directory",5);
		system(("./" . $package_info->{package}->{script}, $tempdir . "/root/")) == 0
			or die_error("Compilation failed: $?",6);
	}
	if($verbose>=1) { print "Moving package...\n"; }
	unless(-d ($prefix . "var")){mkdir ($prefix."var");}
	unless(-d ($prefix . "var/pkg")){mkdir ($prefix."var/pkg");}
	unless(-d ($prefix . "var/pkg/".$pkgname)){mkdir ($prefix."var/pkg/".$pkgname);}
	# Should be more portable, really. But who'll want to install this on Windows?
	system("mv ".$tempdir."/* ".$prefix."var/pkg/".$pkgname);
	my $rootdir = $prefix . "var/pkg/".$pkgname."/root";
	unless(-d $rootdir){ die_error("Moving failed: $?",7); }
	print "Installing files...\n";
	hardlink_copy($rootdir."/", $prefix, $verbose);
	print "Package " . $pkgname . " installed!\n";
	exit(0);
}

my $argv_len = @ARGV;
my $args = 0;
my $command = "nope";
my $package = "";
my $verbose = 0;
my $force = 0;

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
	} elsif($ARGV[$args] eq "-P") {
		if($args<($argv_len-1)) {
			$prefix = $ARGV[$args+1];
			$args++;
		} else { die_error("Prefix not specified.",2); }
	} elsif($ARGV[$args] eq "-v") {
		$verbose+=1;
	} elsif($ARGV[$args] eq "-f") {
		$force=1;
	} elsif($ARGV[$args] eq "chimicherry") {
		print "Cherrychanga!\n";
		exit(0);
	}
}

if($command=="install") { cmd_install($package,$verbose,$force); }
else { die_error("No command specified.\nUse -h for help.\n"); }
