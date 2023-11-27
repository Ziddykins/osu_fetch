#!/usr/bin/env perl

use strict;
use warnings;
use diagnostics;

use utf8;

use Parallel::ForkManager;
use LWP::UserAgent;
use LWP::Simple;

my $ua = LWP::UserAgent->new();
my $pm = Parallel::ForkManager->new(5); # Keep it low, if any

$ua->agent('Osu!Scrape/1.1');
$ua->timeout(5);

# Leave these
my $skip_url_parse  = 0;
my $skip_file_parse = 0;
my @packs;
my @files;
my %get;

### /!\ IMPORTANT /!\ ###
# Get this information via browser - login to Osu and check cookies
# (F12 -> Application tab -> cookies, most browsers; CTRL+Shift+J for Opera)
#     - Required to be able to pull the file url's
#     - Cookie: osu_session
my $session_cookie = '';

# Customize which game modes are pulled
$get{taiko} = 1;
$get{mania} = 1;
$get{catch} = 1;
$get{osu}   = 1;

# Customize which categories they're pulled from
$get{standard}   = 1;
$get{featured}   = 1;
$get{tournament} = 1;
$get{loved}      = 1;
$get{chart}      = 1;
$get{theme}      = 1;
$get{artist}     = 1;

# You can use forks, but chances are it won't play out well;
# i.e. you'll be throttled by the server with a 429 status.
# Forks are only utilized when downloading, as well.
my $use_forks = 1;

my $logfile = 'scraper.log';
open my $fh, '>>', $logfile;

if (-e '.packurls') {
    write_output('WARN', 'FILE_EXIST',  'Pack list found');
    print "Skip scraping?\nChoice [y/n]: ";
    chomp(my $choice = <STDIN>);
    $skip_url_parse = 1 if $choice =~ /[Yy]e?s?/;
}

if (-e '.fileurls') {
    write_output('WARN', 'FILE_EXIST', 'File list found');
    print "Skip scraping?\nChoice [y/n]: ";
    chomp(my $choice = <STDIN>);
    $skip_file_parse = 1 if $choice =~ /[Yy]e?s?/;
}

if (!-d 'downloads') {
    mkdir('downloads');
    write_output('INFO', 'DIR_CREATE', 'Downloads directory created');
}

for (qw/standard featured tournament loved chart theme artist/) {
    my $category = $_;

    if (!-d "downloads/$category") {
        mkdir("downloads/$category");
        write_output('INFO', 'DIR_CREATE', "downloads/$category/ directory created");
    }

    for (qw/osu mania taiko catch/) {
        my $mode = $_;

        if (!-d "downloads/$category/$mode") {
            mkdir("downloads/$category/$mode");
            write_output('INFO', 'DIR_CREATE', "downloads/$category/$mode directory created");
        }
    }
}

if (!$skip_url_parse) {
    for (qw/standard featured tournament loved chart theme artist/) {
        my $category = $_;

        next if !$get{$category}
            and write_output('INFO', 'SKIP_CATEGORY', "Skipping $category due to configuration");

        my $max_page = get_last_page("https://osu.ppy.sh/beatmaps/packs?type=$category");

        for (1 .. $max_page) {
            my $page_num = $_;
            my $url = "https://osu.ppy.sh/beatmaps/packs?type=$category&page=$page_num";
            my $page = $ua->get($url);

            write_output('INFO', 'PAGE_GRAB', "Grabbing page $category:$page_num");

            if ($page->is_success) {
                my $code = $page->decoded_content;
                my @lines = split /[\r\n]/, $code;

                for (my $i=0; $i<scalar @lines - 1; $i++) {
                    if ($lines[$i] =~ /<a href="(https:\/\/osu.ppy.sh\/beatmaps\/packs\/\w+)" class="beatmap-pack__heade.*/) {
                        my $pack = $1;

                        if ($lines[$i+1] =~ /beatmap-pack__name">.*?osu!(taiko|mania|catch)?/){
                            my $which = $1;
                            $which  //= 'osu';
                            my $skip  = 1;

                            write_output('INFO', uc($which) . '_FIND', "Found a $which pack @ $pack");

                            for (qw/taiko mania catch osu/) {
                                my $mode = $_;

                                if ($get{$mode} == 1 && $which eq $mode) {
                                    $skip = 0;
                                    last;
                                }
                            }

                            if (!$skip) {
                                push(@packs, "${category}:::${which}:::$pack");
                                open my $fh_urls, '>>', '.packurls';
                                write_output('INFO', 'PACKURL_STORE', "Got $which pack: $pack");
                                print $fh_urls "${category}:::${which}:::$pack\n";
                                close $fh_urls;
                                
                            } else {
                                write_output('INFO', uc($which) . '_SKIP', "Skipping $which $pack due to configuration");
                            }
                        }
                    }
                }
            } else {
                write_output('ERRO', 'PAGE_GRAB_FAIL', "Couldn't get pack $url - Status: " . $page->status_line . " ($@)");
            }

            $page_num++;
            write_output('INFO', 'PAGE_CHANGE', "Changing to page $page_num");
            sleep 1;
        }
    }
} else {
    open my $fh, '<', '.packurls';
    @packs = <$fh>;
    close $fh;
}

print "Got " . scalar @packs . " URLs to parse for files\n\n";

if (!$skip_file_parse) {
    print "-Press Enter to start file URL parse-";
    <STDIN>;

    my $count = scalar @packs;
    my $current = 1;

    foreach my $pack (@packs) {
        if ($current % 10 == 0) {
            print "Remaining: " . int($count / $current  / 60.0) . "m\n";
        }
        chomp($pack);
        write_output('INFO', 'FILE_PARSE', "Parsing pack URL $pack");
        my ($category, $type, $file_url) = split /:::/, $pack;

        $file_url .= '?format=raw';
       
        my $build_req = req_privileged_url($file_url);
        my $resp = $ua->request($build_req);
        
        if ($resp->is_success) {
            my $content = $resp->decoded_content;
            my @lines = split /[\r\n]/, $content;

            for (1 .. 5) {
                if ($lines[$_] =~ /href="(.*?)"/) {
                    my $pack_url = $1;
                    open my $fh, '>>', '.fileurls';
                    print $fh "${category}:::${type}:::$pack_url\n";
                    close $fh;
                    write_output('INFO', 'DIRECT_LINK', sprintf("[%04d/%04d] -> Got %s URL: %s\n", $current++, $count, $type, $pack_url));
                    push(@files, "${category}:::{$type}:::$pack_url");
                }
            }
        } else {
            write_output('CRIT', 'FETCH_ERROR', "Couldn't pull  $type file at $file_url - Status: " . $resp->status_line . " - $@\n");
        }
        sleep 1;
    }
} else {
    open my $fh, '<', '.fileurls';
    @files = <$fh>;
    close $fh;
}

print "Got " . scalar @files . " URLs to parse for direct files\n\n";
print "-Press Enter to start file downloads-";
<STDIN>;

if ($use_forks) {
    FILES:
    foreach my $file (@files) {
        my $pid = $pm->start and next FILES;
        chomp($file);
        my ($category, $type, $filename) = split /:::/, $file;
        my @split_url = split /\//, $filename;
        my $file = $split_url[-1];
        my $file_path = "downloads/$category/$type/$file";

        next if -e $file_path
            and print "Skipping download, file exists: $file_path\n";

        write_output('INFO', 'DOWNLOAD', "[$$][$pid] Downloading $type file $file from $category");

        getstore($filename, $file_path)
            or warn "Couldn't save file $file_path: $!\n";

        write_output('INFO', 'DOWNLOADED', "[$$][$pid] Downloaded $type file $file from $category");
        sleep 1;
        $pm->finish;
    }
    print "Waiting for child processes to finish\n";
    $pm->wait_all_children;
 } else {
    foreach my $file (@files) {
        chomp($file);
        my ($category, $type, $filename) = split /:::/, $file;
        my @split_url = split /\//, $filename;
        my $file = $split_url[-1];
        my $file_path = "downloads/$category/$type/$file";

        next if -e $file_path
            and print "Skipping download, file exists: $file_path\n";

        write_output('INFO', 'DOWNLOAD', "Downloading $type file $file from $category");

        getstore($filename, $file_path)
            or warn "Couldn't save file $file_path: $!\n";

        write_output('INFO', 'DOWNLOADED', "Downloaded $type file $file from $category");
        sleep 1;
    }
}

print "Done!\n";
close $fh;

sub req_privileged_url {
    my $url = $_[0];

    my $req = HTTP::Request->new(
        'GET' => "$url",
        [
            'Cache-Control'             => 'no-cache',
            'Pragma'                    => 'no-cache',
            'Accept'                    => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'Accept-Encoding'           => 'gzip, x-gzip, deflate, x-bzip2, bzip2',
            'Accept-Language'           => 'en-US,en;q=0.9',
            'User-Agent'                => $ua->agent(),
            'Authority'                 => 'osu.ppy.sh',
            'Cookie'                    => "osu_session=$session_cookie;",
            'Dnt'                       => '1',
            'Sec-Ch-Ua-Mobile'          => '?0',
            'Sec-Ch-Ua-Platform'        => '"Windows"',
            'Sec-Fetch-Dest'            => 'document',
            'Sec-Fetch-Mode'            => 'navigate',
            'Sec-Fetch-Site'            => 'none',
            'Sec-Fetch-User'            => '?1',
            'Upgrade-Insecure-Requests' => '1',
        ],
    );
    return $req;
}

sub write_output {
    my ($severity, $section, $data) = @_;
    my $formatted = sprintf("[% 4s][% 15s] -> %s\n", $severity, $section, $data);
    print $fh "$formatted";
    print "$formatted";
}

sub get_last_page {
    my $url = $_[0];
    my $resp = $ua->get($url);
    my $max = 1;

    if ($resp->is_success) {
        my $src = $resp->decoded_content;
        my @src_lines = split /[\r\n]/, $src;
        foreach my $line (@src_lines) {
            if ($line =~ /;page=(\d+)"/) {
                my $page_num = $1;
                $max = $page_num > $max ? $page_num : $max;
            }
        }
    }

    write_output('INFO', 'GOT_MAXPAGE', "Found highest page number for url: $url ($max)");
    return $max;    
}
