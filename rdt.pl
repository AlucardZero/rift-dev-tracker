#!/usr/bin/env perl
#The MIT License (MIT)
#
#Copyright (c) 2014 Christopher Henning
#
#Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

use strict;
use warnings;
use Net::Twitter;
use XML::RSS::Parser;
use LWP::UserAgent;
use Unicode::Normalize qw(compose);
use XML::LibXML;
use Date::Parse;
use WWW::Shorten 'TinyURL';
use Proc::Daemon;
use IO::Handle qw( );  # For autoflush
use Config::Simple;
use Cwd;

sub format_for_tweeting($);
sub check_post($);

my $cfg = new Config::Simple('./rdt.conf') or die "Failed to read config. $!\n";
# Set debug to 1 for progress messages, set to 2 to print the title of every
# post seen every time
my $DEBUG = $cfg->param('DEBUG');

my $LOG = "./rdt.log";

my $continue = 1;
my $errcount = 0;
$SIG{TERM} = sub { $continue = 0 };
$SIG{INT} = sub { $continue = 0 };

print localtime . ": Starting.\n";

my $lastdate = -1; # timestamp of post last tweeted

my $nt = Net::Twitter->new(
    traits   => [qw/API::RESTv1_1/],
    consumer_key        => $cfg->param('CONSUMER_KEY'),
    consumer_secret     => $cfg->param('CONSUMER_SECRET'),
    access_token        => $cfg->param('ACCESS_TOKEN'),
    access_token_secret => $cfg->param('ACCESS_TOKEN_SECRET'),
    ssl => 1,
    ) or die "Failed to create Net::Twitter object. $!\n";
eval {
  my $verify = $nt->verify_credentials();
};
if ( $@ ) {
  die "Unable to verify Twitter API credentials. Are your keys and tokens correct in the config? $@\n";
}

my $ua = LWP::UserAgent->new(
    agent => 'Opera/9.80 (X11; Linux x86_64) Presto/2.12.388 Version/12.16',
    timeout => 30,
    );

# daemonize
open(STDOUT, ">>$LOG") or die "Failed to re-open STDOUT to $LOG";
open(STDERR, ">&STDOUT") or die "Failed to re-open STDERR to STDOUT";
STDOUT->autoflush(1);

Proc::Daemon::Init( {
  child_STDOUT => "$LOG",
  child_STDERR => "$LOG",
  work_dir => getcwd(),
} );

# Never tweet anything posted before startup.
# Sleep 15 mins before checking again.
if ($lastdate == -1) { 
  $lastdate = time; 
  $DEBUG && print localtime . ": Initial sleep\n"; 
  sleep 900; 
}

# Main loop - check RSS feed, munge new posts, tweet
while ($continue) {
  if ($errcount > 5) { die "Too many errors, dying\n"; }
  $DEBUG && print localtime . ": Asking\n";
  my $xml = $ua->get($cfg->param('RSSURL')) or die "Failed to retrieve RSS. $!\n";
  if (!$xml->is_success) {
    die "Failed to retrieve RSS. $xml->status_line\n";
  }
  my $p = XML::RSS::Parser->new;
  my $feed = $p->parse_string($xml->decoded_content) or die "Failed to parse XML. $!\n";

  my @items = reverse $feed->query('//item'); # assume oldest first
    foreach my $item (@items) {
      my $pubdate = -1;
      $pubdate = check_post($item);
      # already seen this item?
      if ($pubdate < 0) { next; } 
      
      my $text = format_for_tweeting($item);    
      if ($text eq "") { # error formatting tweet or blank tweet, try again later
        $lastdate -= 1; 
        $errcount++;
        last;
      }
      ($DEBUG > 1) && print  " -> " . $text . "\n";
      eval { # try to tweet
        my $result = $nt->update($text);
      };
      if ( $@ ) { 
        print localtime . ": Failed to send tweet. '$@' $lastdate\n"; 
        if ($@ ne "Status is a duplicate" ) { # no tweet and not a dupe, try again later
          $lastdate -= 1; 
          $errcount++;
          last; 
        }
      } 
      $lastdate = $pubdate;
      sleep 3;
    }
  $lastdate += 1; 
  $errcount = 0;
  $DEBUG && print localtime . ": Sleeping\n";
  sleep int(rand(121) + 840); # sleep 14-16 minutes before trying again
}
# Check if we should tweet - Rift
# Return -1 for no, or the timestamp of the post for yes
sub check_post($) {
  my $item = shift;
  my $pubdate = str2time($item->query('pubDate')->text_content);
  ($DEBUG >= 2) && print "   Post @ " . scalar localtime($pubdate) . ": " . $item->query('title')->text_content . "\n";
  if ($pubdate < $lastdate) { # nearby tracker posts can have the same timestamp, so use <
    return -1;
  } 
  return $pubdate;
}
# Munge item for tweeting - Rift
# Return text to be tweeted
sub format_for_tweeting($) {
  my $item = shift;
  my $text = $item->query('title')->text_content;
  $text =~ /^(.*?): (.*)$/;
  my ($dev, $title) = ($1, $2);
  $title = compose($title); $dev = compose($dev); # attempt to reduce to ASCII
  $title = substr($title, 0, 140 - length($dev) - 22 - 22); # 22 = t.co, 22 = '#RIFT/ posted in "" @ '
    $text = "#Rift/$dev posted in \"$title\" @ ";

  my $content = $item->query('content:encoded')->text_content;
  my $doc = XML::LibXML->load_html(string => $content);
  my $url = undef; my $short_url = undef;
  for my $anchor ( $doc->findnodes("//a[\@href]") ) {
    if ($anchor->textContent eq "Jump to post...") {
      $url = $anchor->getAttribute("href");
      $url =~ s/^!(\d+)!//g;
      $short_url = makeashorterlink($url) or last; # get a short URL or give up
#        $url =~ s/^\s+//g; $url =~ s/\s+$//g;
      last;
    }
  }
# no shortened URL, try again later
  if (!defined $short_url) { 
    print localtime . ": No link\n"; 
    return "";
  } 

  return "$text$short_url";
}
