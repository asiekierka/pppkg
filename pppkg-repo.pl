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
use JSON;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);
use Archive::Tar;
use File::Temp qw(tempfile tempdir);
use File::stat;
use Cwd;
use IO::Compress::Gzip;

# USER CONFIG
my $generate_html = true;
my $generate_html_list = true;
my $copy_file = true;
my $copy_file_folder = "repo_files";
my $repo;
sub die_error {
	my $text = shift;
	my $code = shift;
	if(!defined($code) or $code < 1) { $code=1; }
	print "[ERROR] " . $text . "\n";
	chdir("/");
	exit($code);
}
sub readText {
	my $filename = shift;
	my $f = open(FILE, "<", $filename)
		or die_error("Could not read file!",5);
	my $fh_text = "";
	foreach $line (<FILE>) { $fh_text .= $line; };
	close(FILE);
	return $fh_text;
}
sub readJSON {
	my $filename = shift;
	return decode_json(readText($filename));
}
sub writeText {
	my ($filename,$data) = @_;
	my $f = open(FILE, ">", $filename)
		or die_error("Could not write file!",5);
	print FILE $data;
	close(FILE);
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
	$tar->extract() or die_error("[TAR] Couldn't extract!",1);
	unlink("pkg.tar");
	my $tmp = readJSON("info.json");
	mkdir($olddir."/".$copy_file_folder."/".$tmp->{meta}->{name}."/");
	if($copy_file) { system("mv * ".$olddir."/".$copy_file_folder."/".$tmp->{meta}->{name}."/"); }
	else { system("rm -rf *"); }
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
sub generate_html {
	my ($info, $template) = @_;
	$template =~ s/%PACKAGE%/$info->{meta}->{name}/g;
	$template =~ s/%URL%/$info->{meta}->{url}/g;
	$template =~ s/%DESCRIPTION%/$info->{meta}->{description}/g;
	$template =~ s/%VERSION%/$info->{meta}->{version}/g;
	$template =~ s/%DEPENDS%/$info->{meta}->{dependencies}/g;
	$template =~ s/%PROVIDES%/$info->{meta}->{provides}/g;
	my $files_url = $copy_file_folder . "/" . $info->{meta}->{name} . "/";
	$template =~ s/%FILES_URL%/$files_url/g;
	$template =~ s/%PACKAGE_URL%/$info->{filename}/g;
	my $t2 = "<div id=\"".$info->{meta}->{name}."\">".$template."</div>";
	return $t2;
}
$repo = {};
$repo->{packages} = {};
$repo->{providers} = {};
print "pppkg repository generator 0.2 html edition\ncleaning...";

my $html = "";
my $html_temp = readText("TEMPLATE.html");
if(-d $copy_file_folder) { system("rm -rf ".$copy_file_folder); }
mkdir($copy_file_folder);

my $html_list = "<div id=\"_filelist\">";

$tempdir = tempdir("/tmp/pkgist-repo-gen-XXXXXX", CLEANUP => 1);	
print "parsing packages...\n";
my @pkgfiles = `find *.ppk`;
foreach $file (@pkgfiles) {
	$file=~s/\n//g;
	print $file . "...\n";
	$info = read_info($file,$tempdir);
	$repo->{packages}->{($info->{meta}->{name})} = $info;
	db_addpkg($info);
	$html .= generate_html($info,$html_temp);
	$html_list .= "<a href=\"#" . $info->{meta}->{name} . "\">" . $info->{meta}->{name} . "</a><br>";
}
$html_list .= "</div>";

$html_final = "<html><head><title>Repository</title></head><body>";
if($generate_html_list) { $html_final .= $html_list; }
$html_final .= $html . "</body></html>";
writeText("index.html",$html_final);
writeJSONC("repo.json.gz",$repo);
print "done\n";
