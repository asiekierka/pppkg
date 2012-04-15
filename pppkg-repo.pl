#!/usr/bin/perl

use warnings;
use JSON;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);
use Archive::Tar;
use File::Temp qw(tempfile tempdir);
use File::stat;
use Cwd;
use IO::Compress::Gzip;

my $repo;
sub die_error {
	my $text = shift;
	my $code = shift;
	if(!defined($code) or $code < 1) { $code=1; }
	print "[ERROR] " . $text . "\n";
	chdir("/");
	exit($code);
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
sub writeJSONC {
	my ($filename,$data) = @_;
	my $f = new IO::Compress::Gzip $filename
		or die_error("Could not write JSON file!",5);
	print $f encode_json($data);
	close($f);
}
sub read_info {
	my ($src,$destdir) = @_;
	my $stat = stat($src);
	bunzip2 $src => $destdir."/pkg.tar" or die_error("[BZIP2] ".$Bunzip2Error,1);
	my $olddir = getcwd();
	chdir $destdir;
	my $tar = Archive::Tar->new;
	$tar->read("pkg.tar") or die_error("[TAR] Couldn't read!",1);
	$tar->extract("info.json") or die_error("[TAR] Couldn't extract!",1);
	my $tmp = readJSON("info.json");
	unlink("pkg.tar");
	unlink("info.json");
	chdir $olddir;
	$tmp->{mtime} = $stat->mtime;
	$tmp->{filename} = $src;
	return $tmp;
}
sub db_addpkg {
	my ($info) = @_;
	my $pkgname = $info->{meta}->{name};
        my @provides = split(/ /, $info->{meta}->{provides});
        foreach $pr (@provides) {
                if(defined($repo->{providers}->{$pr})) {
                        push(@{$repo->{providers}->{$pr}},$pkgname);
                } else {
                        $repo->{providers}->{$pr} = [$pkgname];
                }
        }
}
$repo = {};
$repo->{packages} = {};
$repo->{providers} = {};
print "pppkg repository generator 0.1\n";

$tempdir = tempdir("/tmp/pkgist-repo-gen-XXXXXX", CLEANUP => 1);	
print "parsing packages...\n";
my @pkgfiles = `find *.ppk`;
foreach $file (@pkgfiles) {
	$file=~s/\n//g;
	print $file . "...\n";
	$info = read_info($file,$tempdir);
	$repo->{packages}->{($info->{meta}->{name})} = $info;
	db_addpkg($info);
}
writeJSONC("repo.json.gz",$repo);
print "done\n";
