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

sub company {
    my $self = shift;
    return $self->{company};
}

sub get_one {
    my $self = shift;
    my %args = @_;
    $args{size} = 1;

    my $result = $self->get_all(%args);
    if (ref $result eq 'ARRAY') {
	return $result->[0];
    }
    return undef;
}

sub get_all {
    my $self = shift;
    my %args = (
	raw => 0,
	@_,
    );
    my $items = [];

    my $raw = $args{raw};

    my $pagesize = 50; # default, but don't assume!
    my $maxitems = $args{size};
    delete $args{size};

    my $offset = 0;

    while (1) {
	my $fetchsize = ((defined($maxitems) and $maxitems < $pagesize) ? $maxitems : $pagesize);
	if (my $json = $self->_get(%args, size => $fetchsize, offset => $offset)) {
	    if ($json->{status} == 200) {
		if (my $jsonitems = _jsonitems($json)) {
		    if ($raw){
			push (@$items, $json->{json});
		    }
		    else {
			push(@$items, @{$jsonitems});
		    }
		    # this should not be needed but at least once we have
		    # had items returned at offsets where they don't exist.
		    last if (@$jsonitems < $pagesize);
		}
		else {
		    last;	# no more items
		}

		# handle paging
		if (defined($maxitems)) {
		    if (($maxitems -= $fetchsize) <= 0) {
			last;
		    }
		}
		$offset += $fetchsize;
	    }
	    else {
		croak "$self->{company}: get_all(@{[Data::Dumper->Dump([\%args], [qw(args)])]}): $json->{status} $json->{errmsg}\n";
	    }
	}
	else {
	    # no results
	    last;
	}
    }

    return $items;
}

# similar to get_all, but for data (do not try to page, as it is very weird and undocumented)
sub get_data_nonpaged {
    my $self = shift;
    my %args = @_;
    my $items = [];

    # normalize period to start/end (uses millsecond epoch, not properly documented)
    my $etime;
    my $stime;
    if (defined $args{period}) {
	$etime = int time;
	$stime = $etime - (3600 * $args{period});
    }
    else {
	$etime = $args{start};
	$stime = $args{end};
    }
    croak "$self->{company}: get_data: start time not defined" unless defined $stime;
    croak "$self->{company}: get_data: end time not defined" unless defined $etime;
    croak "$self->{company}: get_data: time warp (start after end)" if $stime > $etime;
    $stime *= 1000;
    $etime *= 1000;

    # get one page of data, ignore the rest
    if (my $json = $self->_get(%args, start => $stime, end => $etime)) {
	if ($json->{status} == 200) {
	    if (my $jsonitems = _jsonitems($json)) {
		push(@$items, @{$jsonitems});
	    }
	}
	else {
	    croak "$self->{company}: get_data: $json->{status} $json->{errmsg}\n" unless
		$json->{status} == 1007		# Such datapoints([XXX]) do not belong to current datasource(ID=NNN).
	     or $json->{status} == 1069;	# device<NNN> has no such DeviceDataSource
	}
    }

    return $items;
}

sub _jsonitems {
    my $json = shift;
    my $items;

    if (exists $json->{data}->{items}) {
	if (ref $json->{data}->{items} eq 'ARRAY' and @{$json->{data}->{items}}) {
	    push(@$items, @{$json->{data}->{items}});
	}
	elsif (ref $json->{data}->{items} eq 'HASH') {
	    push(@$items, $json->{data}->{items});
	}
    }
    elsif (exists $json->{items}) {
	if (ref $json->{items} eq 'ARRAY' and @{$json->{items}}) {
	    push(@$items, @{$json->{items}});
	}
	elsif (ref $json->{items} eq 'HASH') {
	    push(@$items, $json->{items});
	}
    }
    elsif (exists $json->{data}) {
	if (ref $json->{data} eq 'HASH') {
	    push(@$items, $json->{data});
	}
    }

    return $items;
}

sub _version {
    my $self = shift;
    my %opts = @_;

    my $version = $opts{'version'};
    if (defined($version) and length($version)) {
	$version = int($version);
    }
    else {
	my $path = $opts{'path'};
	if ($path =~ m:^(/setting/netscans/|/device/devices/\d+/flows|/setting/alert/internalalerts|/debug$):) {
	    $version = 2;
	}
	elsif ($path =~ m:^/setting/(role|admin)/groups:) {
	    $version = 3;
	}
	elsif ($path =~ m:^/setting/(oids|functions|configsources|eventsources|propertyrules|batchjobs|topologysources|registry|alert/dependencyrules)\b:) {
	    $version = 3;
	}
	elsif ($path =~ m:^(/device/unmonitoreddevices)$:) {
	    $version = 3;
	}
	elsif ($path =~ m:^(/website/websites)$:) {
	    $version = 3;
	}
	else {
	    $version = 1;
	}
    }

    return $version;
}

# internal method, used by get_all to deal with paging
sub _get {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};

    my $raw = 0;
    $raw = $opts{'raw'} if defined $opts{'raw'};

    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);

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
	# 'Referer' => $self->{referbase},
    );
    if ($version > 1) {
	push(@headers, "X-version" => "$version");
    }
    while (1) {
	my $req = GET $url, @headers;
	if (my $response = $ua->request( $req )) {
	    if ($response->is_success) {
		my $hash = from_json($response->content);
		if ($raw){
		    $hash->{json} = $response->content;
		}
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
    my @args;

    my $path = $opts{'path'};
    my $content = $opts{'content'};

    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);

    for my $prop (qw(_scope collectorId)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'PUT', %opts);

    # setup HTTP agent and headers
    my $ua = LWP::UserAgent->new();
    my $url = $self->{baseurl} . $path;
    $url .= sprintf("?%s", join('&', @args)) if @args;
    my @headers = (
	'Authorization' => $auth,
	'Content-Type' => 'application/json',
	'Content' => $content,
    );
    if ($version > 1) {
	push(@headers, "X-version" => "$version");
    }

    my $req = PUT $url, @headers;
    if (my $response = $ua->request( $req )) {
	if ($response->is_success) {
	    return from_json($response->content);
	}
	else {
	    carp "Problem with request:\n", 
		 "    Request: $url\n", 
		 "    Response Status: ", $response->status_line . "\n";
	    return undef;
	}
    }
}

sub post {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};
    my $content = $opts{'content'};
    #
    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);

    for my $prop (qw(_scope collectorId)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'POST', %opts);

    # setup HTTP agent and headers
    my $ua = LWP::UserAgent->new();
    my $url = $self->{baseurl} . $path;
    $url .= sprintf("?%s", join('&', @args)) if @args;
    my @headers = (
	'Authorization' => $auth,
	'Content-Type' => 'application/json',
	'Content' => $content,
    );
    if ($version > 1) {
	push(@headers, "X-version" => "$version");
    }

    my $req = POST $url, @headers;
    if (my $response = $ua->request( $req )) {
	if ($response->is_success) {
	    return from_json($response->content);
	}
	else {
	    carp "Problem with request:\n", 
		 "    Request: $url\n", 
		 "    Response Status: ", $response->status_line . "\n";
	    return undef;
	}
    }
}

sub patch {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};
    my $content = $opts{'content'};
    #
    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);

    for my $prop (qw(_scope collectorId patchFields)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'PATCH', %opts);

    # setup HTTP agent and headers
    my $ua = LWP::UserAgent->new();
    my $url = $self->{baseurl} . $path;
    $url .= sprintf("?%s", join('&', @args)) if @args;
    my @headers = (
	'Authorization' => $auth,
	'Content-Type' => 'application/json',
    );
    if ($version > 1) {
	push(@headers, "X-version" => "$version");
    }

    # LWP versions currently deployed don't natively support
    # HTTP 'PATCH'.
    my $req = HTTP::Request->new('PATCH', $url, \@headers, $content);
    if (my $response = $ua->request( $req )) {
	if ($response->is_success) {
	    return from_json($response->content);
	}
	else {
	    carp "Problem with request:\n", 
		 "    Request: $url\n", 
		 "    Response Status: ", $response->status_line . "\n";
	    return undef;
	}
    }
}

sub lmapiauth {
    my $self = shift;
    my %opts = @_;

    my $path = $opts{'path'};
    my $method = $opts{'method'};
    my $content = "";

    $content = $opts{'content'} if ($method eq "PUT" or $method eq "POST" or $method eq "PATCH");
    
    # construct authorization string
    my $epoch = int(time * 1000);	# time in ms
    my $requestVars = "${method}${epoch}${content}${path}";
    my $signature = MIME::Base64::encode(hmac_sha256_hex($requestVars, $self->{access_key}), "");
    return "LMv1 $self->{access_id}:${signature}:${epoch}";
}

1;
