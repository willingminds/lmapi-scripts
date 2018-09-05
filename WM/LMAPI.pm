package WM::LMAPI;

#------------------------------------------------------------------------------
# Copyright (c) 2018 by Willing Minds LLC
# All Rights Reserved.
#
# 1240 N. Van Buren Street #107
# Anaheim, CA 92807
#
# 714-630-4772 (voice)
# 714-844-4698 (fax)
#
# http://www.willingminds.com/
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#------------------------------------------------------------------------------

use Carp;
use HTTP::Request::Common;
use LWP 5.8;
use JSON;
use YAML ();
###use Hash::Merge qw(merge);
use Time::HiRes qw(time);
use Digest::SHA qw(hmac_sha256_hex);
use MIME::Base64 ();
use Data::Dumper;

use strict;
use warnings;

#------------------------------------------------------------------------------

sub new {
    my $this = shift;
    my $class = ref($this) || $this;
    my $self = {};
    bless $self, $class;
    $self->initialize(@_);
    return $self;
}

# arguments:
#
#  credfile => PATH (optional, default to $HOME/.lmapi)
#  company => NAME (required, key into credfile)

sub initialize {
    my $self = shift;
    my %opts = @_;
    $opts{credfile} ||= "$ENV{HOME}/.lmapi";

    croak "ERROR: missing required argument 'company'\n" if not defined $opts{company};
    my $company = $opts{company};

    my $yaml = YAML->new or croak "unable to create YAML object: $!\n";
    my $lmapi = YAML::LoadFile($opts{credfile}) or croak "unable to load API credentials from $opts{credfile}\n";

    croak "ERROR: unable to find companies section\n" if not defined($lmapi->{companies});
    croak "ERROR: error in companies section definition\n" if ref $lmapi->{companies} ne 'HASH';

    my $lmapi_base = $lmapi->{companies}->{$company};
    croak "ERROR: unable to find company '$company' in the companies section\n" if not defined($lmapi_base);

    $self->{access_id} = $lmapi_base->{access_id};
    $self->{access_key} = $lmapi_base->{access_key};
    $self->{company} = $company;
    $self->{baseurl} = "https://${company}.logicmonitor.com/santaba/rest";
    $self->{referbase} = "https://${company}.logicmonitor.com/santaba/uiv3";
}

sub get_all {
    my $self = shift;
    my %args = @_;
    my $items = [];

    my $pagesize = 50; # default, but don't assume!
    my $maxitems = $args{size};
    delete $args{size};

    my $offset = 0;
    while (1) {
	my $fetchsize = ((defined($maxitems) and $maxitems < $pagesize) ? $maxitems : $pagesize);
	if (my $json = $self->_get(%args, size => $fetchsize, offset => $offset)) {
	    if ($json->{status} == 200) {
		if (exists $json->{data}->{items}) {
		    if (ref $json->{data}->{items} eq 'ARRAY' and @{$json->{data}->{items}}) {
			push(@$items, @{$json->{data}->{items}});
		    }
		    elsif (ref $json->{data}->{items} eq 'HASH') {
			push(@$items, $json->{data}->{items});
		    }
		    else {
			last;	# no more items
		    }
		}
		elsif (exists $json->{items}) {
		    if (ref $json->{items} eq 'ARRAY' and @{$json->{items}}) {
			push(@$items, @{$json->{items}});
		    }
		    elsif (ref $json->{items} eq 'HASH') {
			push(@$items, $json->{items});
		    }
		    else {
			last;	# no more items
		    }
		}
		if (defined($maxitems)) {
		    if (($maxitems -= $fetchsize) <= 0) {
			last;
		    }
		}
		$offset += $fetchsize;
	    }
	    else {
		croak "get_all: $json->{status} $json->{errmsg}\n";
	    }
	}
	else {
	    last;
	}
    }

    return $items;
}

# internal method, used by get_all to deal with paging
sub _get {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};

    # extract explicit version, or set version implicitly for specific paths
    my $version = $opts{'version'};
    if (defined($version) and length($version)) {
	$version = int($version);
    }
    else {
	if ($path =~ m:^(/setting/netscans/|/device/devices/\d+/flows|/setting/alert/internalalerts):) {
	    $version = 2;
	}
	else {
	    $version = 1;
	}
    }

    for my $prop (qw(size sort filter fields offset format period datapoints)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'GET', %opts);
    
    # setup HTTP agent and headers
    my $ua = LWP::UserAgent->new();
    my $url = $self->{baseurl} . $path;
    $url .= sprintf("?%s", join('&', @args)) if @args;
    my @headers = (
	'Authorization' => $auth,
	'Content-Type' => 'application/json',
	'Accept' => 'application/json',
    );
    if ($version > 1) {
	push(@headers, "X-version" => "$version");
    }
    while (1) {
	my $req = GET $url, @headers;
	if (my $response = $ua->request( $req )) {
	    if ($response->is_success) {
		my $hash = from_json($response->content);
		$hash->{status} = $response->code unless defined $hash->{status};
		return $hash;
	    }
	    elsif ($response->status_line =~ /^429\s/ and $response->header('X-Rate-Limit-Remaining') == 0) {
		my $window = $response->header('X-Rate-Limit-Window');
		if (defined $window and $window > 0) {
		    sleep($window);
		}
	    }
	    else {
		carp "Problem with request:\n", 
		     "    Request: $url\n", 
		     "    Response Status: ", $response->status_line . "\n";
		return undef;
	    }
	}
    }
}

sub put {
    my $self = shift;
    my %opts = @_;

    my $path = $opts{'path'};
    my $content = $opts{'content'};

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'PUT', %opts);

    # setup HTTP agent and headers
    my $ua = LWP::UserAgent->new();
    my $url = $self->{baseurl} . $path;
    my $req = PUT $url, 'Authorization' => $auth, 'Content-Type' => 'application/json', 'Content' => $content;
    if (my $response = $ua->request( $req )) {
	if (not $response->is_success) {
	    carp "Response Status: ", $response->status_line. "\n";
	}
    }
}

sub post {
    my $self = shift;
    my %opts = @_;

    my $path = $opts{'path'};
    my $content = $opts{'content'};

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'POST', %opts);

    # setup HTTP agent and headers
    my $ua = LWP::UserAgent->new();
    my $url = $self->{baseurl} . $path;
    my $req = POST $url, 'Authorization' => $auth, 'Content-Type' => 'application/json', 'Content' => $content;
    if (my $response = $ua->request( $req )) {
	if ($response->is_success) {
	    return from_json($response->content);
	}
	else {
	    carp "Response Status: ", $response->status_line. "\n";
	}
    }
}

sub lmapiauth {
    my $self = shift;
    my %opts = @_;

    my $path = $opts{'path'};
    my $method = $opts{'method'};
    my $content = "";

    $content = $opts{'content'} if ($method eq "PUT" or $method eq "POST");
    
    # construct authorization string
    my $epoch = int(time * 1000);	# time in ms
    my $requestVars = "${method}${epoch}${content}${path}";
    my $signature = MIME::Base64::encode(hmac_sha256_hex($requestVars, $self->{access_key}), "");
    return "LMv1 $self->{access_id}:${signature}:${epoch}";
}

1;
