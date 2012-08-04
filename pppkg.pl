#!/usr/bin/perl

#  Copyright (C) 2012 Adrian Siekierka
#
#  This software is provided 'as-is', without any express or implied
#  warranty.  In no event will the authors be held liable for any damages
#  arising from the use of this software.
#
#  Permission is granted to anyone to use this software for any purpose,
#  including commercial applications, and to alter it and redistribute it
#  freely, subject to the following restrictions:
#
#  1. The origin of this software must not be misrepresented; you must not
#     claim that you wrote the original software. If you use this software
#     in a product, an acknowledgment in the product documentation would be
#     appreciated but is not required.
#  2. Altered source versions must be plainly marked as such, and must not be
#     misrepresented as being the original software.
#  3. This notice may not be removed or altered from any source distribution.

use warnings;

# ERRORCODES:
# 1 - general, 2 - commands, 3 - file doesn't exist, 4 - unpacking error, 5 - JSON error,
# 6 - compile error, 7 - move error, 8 - filelist error, 9 - unlink error, 10 - removal finalize error,
# 11 - package is installed, 12 - repo not found, 13 - DL error, 14 - no package in DB,
# 15 - deps error
# DEPENDENCIES
# Builtin
use File::Temp qw(tempfile tempdir);
use Archive::Tar;
use File::Copy;
use File::Path qw(rmtree);
use IO::Compress::Gzip;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Cwd;
use HTTP::Tiny;
# Additional
use JSON;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);

# VARIABLES
my $command = "nope";
my $package = "";
my $package_ext= ".ppk";
my $verbose = 0;
my $force = 0;
my $compile = 0;
my $mtime = 0;
my $prefix = "/";
my $db;
my $config;
my $http = HTTP::Tiny->new;
my $dlprefix = "";
my $dep_depth = 15;
# SUBROUTINES
sub download_file {
	my ($url, $out) = @_;
	my $f = open(FILE, ">", $out)
		or die_error("Error opening file '".$out."' for writing!",13);
	my $response = $http->get($url);
	die_error("Errror download file '".$url."'!",13) unless $response->{success};
	print FILE $response->{content};
	close(FILE);
}
sub die_error {
	my $text = shift;
	my $code = shift;
	if(!defined($code) or $code < 1) { $code=1; }
	print "[ERROR] " . $text . "\n";
	chdir("/");
	exit($code);
}
sub hardlink_copy {
	my ($src, $dest, $pkgname) = @_;
	# Screw the Perl ways! Bash on it!
	open(FILELIST, ">","filelist")
		or die_error("Cannot create filelist!",8);
	chdir $src;
	my @files = `find *`;
	foreach $file (@files) {
		print FILELIST $file;
		$file=~s/\n//g;
		if($command eq "reinstall" && !db_owns($pkgname,$file)) { next; }
		if($verbose>=2) { print $dest.$file . "\n"; }
		if(-f $dest.$file) { unlink $dest.$file; if($command ne "reinstall"){ print "Overwriting " . $file . "!\n"; } }
		if(-l $src.$file) {
			unless(-e ($dest.$file)) { symlink(readlink($src.$file),$dest.$file); }
		}
		elsif(-f $src.$file) {
			$errcode = system("ln ".$src.$file." ".$dest.$file);
			unless($errcode==0) { if($force<1) { print "[WARNING] Error while hardlinking " . $file . "!\n"; } }
		} elsif(-d $src.$file) {
			unless(-d ($dest.$file)) {mkdir ($dest.$file);}
		}
	}
	close(FILELIST);
	return @files;
}
sub read_filelist {
	my ($fn) = @_;
	open(FILELIST, "<",$fn)
		or die_error("Cannot read filelist!",8);
	my @files = ();
	foreach $file(<FILELIST>) {
		$file=~s/\n//g;
		push(@files,$file);
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
sub is_installed {
	my ($name) = @_;
	return (exists($db->{packages}->{$name}) || exists($db->{providers}->{$name}));
}
sub check_dependencies {
	my ($deps) = @_;
	my @deparr = split(/ /,$deps);
	my @neededdeps;
	if($force>0) { return @neededdeps; } # That is, nothing.
	foreach $dep (@deparr) {
		if(!is_installed($dep)) { push(@neededdeps,$dep); }
	}
	return @neededdeps;
}
sub check_deps_die {
	my ($deps) = @_;
	my @n_deps = check_dependencies($deps);
	my $n_dlen = @n_deps;
	if($n_dlen>0) { die_error("Resolve dependencies first: ".join(', ',@n_deps),15); }
}
# DATABASE
sub db_owns {
	my ($name, $filename) = @_;
	my @arr = @{$db->{files}->{$filename}};
	my $al = @arr;
	if($verbose>=2) { print "Checking if ".$arr[$al-1]." equals ".$name." for filename ".$filename."... ".($arr[$al-1] eq $name)."\n"; }
	return ($arr[$al-1] eq $name);
}
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
					$src = $prefix."var/pkg/files/".$last_app."/root/";
					if(-f $src.$file) {
						if(-f $prefix.$file) { unlink($prefix.$file); }
						$errcode = system("ln ".$src.$file." ".$prefix.$file);
						unless($errcode==0) { print "[WARNING] Couldn't hardlink file ".$file."!"; }
					}
				}
			}
		}
	}
	delete $db->{packages}->{$name};
}
sub db_update {
	writeJSONC($prefix."var/pkg/db.json",$db);
}
sub unpack_pkg {
	my ($src, $dest) = @_;
	bunzip2 $src => $dest."/pkg.tar" or die_error("[BZIP2] ".$Bunzip2Error,4);
	my $olddir = getcwd();
	chdir $dest;
	Archive::Tar->extract_archive("pkg.tar") or die_error("[TAR] An error!",4);
	unlink("pkg.tar");
	chdir $olddir;
}
# COMMANDS
sub cmd_help {
	print "\n[ Portable(-ish) Perl PacKaGist 0.3 ]\n";
	print "LOCAL COMMANDS:\n";
	print "\t-h\t\tHelp\n\t-i [pkg" . $package_ext . "]\tInstall package file\n";
	print "\t-r [pkg-name]\tRemove package\n\t-l\t\tList installed packages\n";
	print "\nREPOSITORY:\n\t-u\t\tUpdate repo\n\t-d [pkg]\tDownload package\n";
	print "\t-di [pkg]\tDownload and install package\n\t-dRi [pkg]\tDownload and reinstall package\n";
	print "\nOPTIONS:\n";
	print "\t-v\t\tVerbose\n\t-f\t\tForce (unfinished)\n\t\-P [prefix]\tPrefix folder\n";
	print "\t-C\t\tPrefer compiling\n";
}
sub cmd_list {
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
	my $pkgdir = $prefix."var/pkg/files/".$package;
	if(!is_installed($package)){ die_error("The package is not installed! Install it first.",11); }
	# Abuse the fact that the filelist is generated during the hardlinking.
	print "Removing package " . $package . "...\n";
	if(defined($package_info->{package}->{preuninstall})) { chdir $pkgdir; exec_script("./" . $package_info->{package}->{preuninstall}); }
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
	if(defined($package_info->{package}->{postuninstall})) { chdir $pkgdir; exec_script("./" . $package_info->{package}->{postuninstall}); }
	db_removepkg($package,read_filelist($pkgdir."/filelist"));
	db_update();
	chdir "/";
	rmtree($pkgdir)
		or die_error("Couldn't finalize package removal!",10);
	print "Package ".$package." uninstalled successfully!\n";
}
sub exec_script {
	my $name = shift;
	system($name) == 0
		or die_error("Running script failed: $?",6);
}
sub cmd_install {
	print "Installing package " . $package . "...\n";
	unless(-f $package) { $package=$package.$package_ext;
		unless(-f $package) { die_error("File doesn't exist",3); }
	}
	if($verbose>=2) { print "Creating tempdir...\n"; }
	$tempdir = tempdir("/tmp/pkgist-XXXXXXXX", CLEANUP => ($verbose>1?0:1));
	if($verbose>=1) { print "Unpacking package...\n"; }
	unpack_pkg($package,$tempdir);
	chdir $tempdir;
	print "Reading package...\n";
	my $package_info = readJSON("info.json");
	my $pkgname = $package_info->{meta}->{name};
	if(is_installed($pkgname) && $command ne "reinstall"){ die_error("The package is already installed! Uninstall it first.",11); }
	check_deps_die($package_info->{meta}->{dependencies});
	my $pkgdir = $prefix."var/pkg/files/".$pkgname;
	my $rootdir = $pkgdir."/root";
	if(!(-d "root") or ($compile==1 and ($package_info->{package}->{script} ne "")))
	{
		print "Compiling...\n";
		if(-d "root") { rmtree("root") or die_error("Couldn't remove rootdir!",5); }
		mkdir "root" or die_error("Couldn't create directory",5);
		system(($config->{flags} . " ./" . $package_info->{package}->{script} . " " . $tempdir . "/root/")) == 0
			or die_error("Compilation failed: $?",6);
	}
	if(defined($package_info->{package}->{preinstall})) { exec_script("./" . $package_info->{package}->{preinstall}); }
	if($verbose>=1) { print "Moving package...\n"; }
	# Should be more portable, really. But who'll want to install this on Windows?
	# Is that even possible?
	if($command eq "reinstall") { system("rm -rf ".$pkgdir); }
	unless(-d ($pkgdir)){mkdir ($pkgdir);}
	system("mv ".$tempdir."/* ".$pkgdir);
	unless(-d $rootdir){ die_error("Moving failed: $?",7); }
	print "Installing files...\n";
	chdir $pkgdir;
	my @filelist = hardlink_copy($rootdir."/", $prefix, $pkgname);
	if(defined($package_info->{package}->{postinstall})) { chdir $pkgdir; exec_script("./" . $package_info->{package}->{postinstall}); }
	db_addpkg($package_info,@filelist);
	db_update();
	print "Package " . $pkgname . " installed!\n";
}

my $argv_len = @ARGV;
my $args = 0;


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
	} elsif($ARGV[$args] eq "-Ri") {
		if($args<($argv_len-1)) {
			$command = "reinstall";
			$package = $ARGV[$args+1];
			$args++;
		} else { die_error("Package not specified.",2); }
	} elsif($ARGV[$args] eq "-P") {
		if($args<($argv_len-1)) {
			$prefix = $ARGV[$args+1];
			$args++;
		} else { die_error("Prefix not specified.",2); }
	} elsif($ARGV[$args] eq "--set_mtime") {
		if($args<($argv_len-1)) {
			$mtime = $ARGV[$args+1];
			$args++;
		}
	} elsif($ARGV[$args] eq "-d") {
		if($args<($argv_len-1)) {
			$command = "download";
			$package = $ARGV[$args+1];
			$args++;
		} else { die_error("Package not specified.",2); }
	} elsif($ARGV[$args] eq "-di") {
		if($args<($argv_len-1)) {
			$command = "di";
			$package = $ARGV[$args+1];
			$args++;
		} else { die_error("Package not specified.",2); }
        } elsif($ARGV[$args] eq "-dRi") {
                if($args<($argv_len-1)) {
                        $command = "dri";
                        $package = $ARGV[$args+1];
                        $args++;
                } else { die_error("Package not specified.",2); }
	} elsif($ARGV[$args] eq "-l") {
		$command = "list";
	} elsif($ARGV[$args] eq "-u") {
		$command = "update";
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
unless(-d ($prefix . "etc")){mkdir ($prefix."etc");}
unless(-d ($prefix . "var/pkg")){mkdir ($prefix."var/pkg");}
unless(-d ($prefix . "var/pkg/files")){mkdir ($prefix."var/pkg/files");}
# Create empty DB if needed.
unless(-f ($prefix . "var/pkg/db.json")){
	$db = {};
	$db->{packages} = {};
	$db->{providers} = {};
	$db->{files} = {};
	writeJSONC($prefix."var/pkg/db.json",$db);
}
unless(-f ($prefix . "etc/pppkg.json")){
	$config = {};
	$config->{flags} = "";
	writeJSON($prefix."etc/pppkg.json",$config);
}
# Commands.
if($command ne "nope")
{
	print "Loading config/database...";
	$config = readJSON($prefix . "etc/pppkg.json");
	$db = readJSONC($prefix . "var/pkg/db.json");
	print " complete\n";	
}

if($command eq "download" || $command eq "di" || $command eq "dri")
{
        unless(-f ($prefix . "var/pkg/repo.json")) { die_error("Repo not found!",12); }
        print "Loading repository...";
        $repo = readJSONC($prefix . "var/pkg/repo.json");
        print " complete\n";
}
sub process_cmd {
	if($command eq "download" || $command eq "di" || $command eq "dri")
	{
		print "Searching for package '".$package."'...\n";
		if(!exists($repo->{packages}->{$package}) && exists($repo->{providers}->{$package}))
		{
			my @prs = @{$repo->{providers}->{$package}};
			print "Found in package ".$prs[$#prs]."\n";
			$package = $prs[$#prs];
		}
		if(exists($repo->{packages}->{$package}))
		{
			my $deps = $repo->{packages}->{$package}->{meta}->{dependencies};
			my $fn = $repo->{packages}->{$package}->{filename};
			if($dep_depth<1) { check_deps_die($deps); }
			my @deps = check_dependencies($deps);
			my $dlen = @deps;
			if($dlen>0)
			{
				$dep_depth--;
				my $oldpkg = $package;
				foreach $dep (@deps) {
					my $oldcmd = $command;
					$package = $dep;
					process_cmd();
					$command = $oldcmd;
				}
				$package = $oldpkg;
			}
			if($command ne "dri" && is_installed($package)){ die_error("The package is already installed! Uninstall it first.",11); }
			print "Downloading...\n";
			if($command eq "di") {
				$dlprefix = tempdir("/tmp/pkgdl-XXXXXX", CLEANUP => ($verbose>1?0:1)) . "/";
			}
			chdir $dlprefix;
			download_file($config->{repo} . "/" . $repo->{packages}->{$package}->{filename}, $repo->{packages}->{$package}->{filename});
			print "Downloaded!\n";
		}
		else { die_error("Package not found!",14); }
	}
	if($command eq "di") {
		print "Installing...\n";
		$package = $dlprefix . $repo->{packages}->{$package}->{filename};
		$command = "install";
		cmd_install();
	} elsif($command eq "dri") {
                print "Installing...\n";
                $package = $dlprefix . $repo->{packages}->{$package}->{filename};
                $command = "reinstall";
                cmd_install();
	} elsif($command eq "update") {
		print "Downloading new repo...\n";
		download_file($config->{repo} . "/repo.json.gz", $prefix . "var/pkg/repo.json.gz");
		print "Unpacking...\n";
		gunzip $prefix . "var/pkg/repo.json.gz" => $prefix . "var/pkg/repo.json"
			or die_error("Couldn't unpack repo! $GunzipError",4);
		print "Done!\n";
	} elsif($command eq "install" || $command eq "reinstall") { cmd_install(); }
	elsif($command eq "remove") { cmd_uninstall(); }
	elsif($command eq "list") { cmd_list(); }
	else { die_error("No command specified.\nUse -h for help."); }
}
process_cmd();
exit(0);
