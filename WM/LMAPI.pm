package WM::LMAPI;

#------------------------------------------------------------------------------
# Copyright (c) 2018-2023 by Willing Minds LLC
# All Rights Reserved.
#
# 9811 W. Charleston Blvd. Ste 2-779
# Las Vegas NV 89117
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
use Scalar::Util qw(reftype);
use URI::Escape;
use Data::Dumper;

use strict;
use warnings;

our $TRACE  = 0;
our $DRYRUN = 0;

#------------------------------------------------------------------------------
sub trace ($@) {
    my $mintrace = shift;
    print "TRACE: " . join("", @_) if $TRACE >= $mintrace;
}

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

    if ($opts{trace}) {
	$TRACE = $opts{trace};
    }
    trace(1, "Trace level set to $TRACE\n");
    if ($opts{dryrun}) {
	$DRYRUN = $opts{dryrun};
    }
    warn "LMAPI: DRYRUN is ON -- No changes will be committed to LogicMonitor\n" if $DRYRUN;

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
	    my $apiversion = $self->_version(%args);
	    my $errorCode;
	    if ($apiversion < 2 and $json->{status} != 200) {
		$errorCode = $json->{status};
	    }
	    elsif (defined $json->{errorCode}) {
		$errorCode = $json->{errorCode};
	    }
	    elsif (defined $json->{errmsg} and lc $json->{errmsg} ne 'ok') {
		$errorCode = $json->{status};	# hack to workaround API bug (errorCode not always generated as documented)
	    }
	    if (defined $errorCode) {
		# if ANY intermediate call fails, invalidate the entire collection
		$self->_condbail($apiversion,$errorCode,$json,\%args);
		$items = [];
		last;
	    }
	    else {
		if (my $jsonitems = _jsonitems($json)) {
		    if ($raw) {
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
	}
	else {
	    # Shouldn't ever get here. The call to _get() should always return a 
	    # hash with status.  If we do somehow get here, invalidate collection 
	    # because who knows what state it's in.
	    $items = [];
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
	$stime = $args{start};
	$etime = $args{end};
    }
    croak $self->company, ": get_data: start time not defined" unless defined $stime;
    croak $self->company, ": get_data: end time not defined" unless defined $etime;
    croak $self->company, ": get_data: time warp: start '$stime' is after end '$etime'" if $stime > $etime;
    #
    # Oddly, at least for data from /website/websites, start and end are regular Unix epoch values
    # even though the data returned in in millisecond epoch values.
    #
    #$stime *= 1000;
    #$etime *= 1000;

    # get one page of data, ignore the rest
    if (my $json = $self->_get(%args, start => $stime, end => $etime)) {
	my $apiversion = $self->_version(%args);
	my $errorCode;
	if ($apiversion < 2 and $json->{status} != 200) {
	    $errorCode = $json->{status};
	}
	elsif (defined $json->{errorCode}) {
	    $errorCode = $json->{errorCode};
	}
	elsif (defined $json->{errmsg} and length $json->{errmsg}) {
	    $errorCode = $json->{status};	# hack to workaround API bug (errorCode not always generated as documented)
	}
	if (defined $errorCode) {
	    # if ANY intermediate call fails, invalidate the entire collection
	    $self->_condbail($apiversion,$errorCode,$json,\%args);
	    $items = [];
	    last;
	}
	else {
	    if ($json->{status} == 200) {
		if (my $jsonitems = _jsonitems($json)) {
		    push(@$items, @{$jsonitems});
		}
	    }
	}
    }

    return $items;
}

sub _condbail {
    my $self = shift;
    my $apiversion = shift;
    my $errorCode = shift;
    my $json = shift;
    my $args = shift;

    if ($apiversion == 1) {
	if ($json->{status} == 1007	or	# Such datapoints([XXX]) do not belong to current datasource(ID=NNN).
	    $json->{status} == 1069) {	# device<NNN> has no such DeviceDataSource
	    # no action, this should just result in an undef result
	    return;
	}
    }
    else {
	return if $errorCode == 404;
    }

    my $request_data = "";
    if ($self->{_last_request}) {
	 $request_data = "\nraw request:\n" . $self->{_last_request}->as_string;
    }
    croak "$self->{company}: get_all(@{[Data::Dumper->Dump([$args], [qw(args)])]}): $json->{status} $json->{errmsg}$request_data\n";
}

sub _jsonitems {
    my $json = shift;
    my $items;

    if (exists $json->{data} and ref $json->{data} eq 'HASH') {
	if (exists $json->{data}->{items}) {
	    # v1, items key
	    if (ref $json->{data}->{items} eq 'ARRAY' and @{$json->{data}->{items}}) {
		push(@$items, @{$json->{data}->{items}});
	    }
	    elsif (ref $json->{data}->{items} eq 'HASH') {
		push(@$items, $json->{data}->{items});
	    }
	}
	else {
	    # v1, no items key
	    push(@$items, $json->{data});
	}
    }
    else {
	if (exists $json->{items}) {
	    # v2+, items key
	    if (ref $json->{items} eq 'ARRAY' and @{$json->{items}}) {
		push(@$items, @{$json->{items}});
	    }
	    elsif (ref $json->{items} eq 'HASH') {
		push(@$items, $json->{items});
	    }
	}
	else {
	    # v2+, no items key
	    push(@$items, $json);
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
	if ($path =~ m{^/setting/(role|admin)/groups}) {
	    $version = 3;
	}
	elsif ($path =~ m{^/setting/(oids|functions|configsources|eventsources|propertyrules|batchjobs|topologysources|registry|alert/(dependencyrules|rules)|companySetting|accesslogs)\b}) {
	    $version = 3;
	}
	elsif ($path =~ m{^/device/unmonitoreddevices$}) {
	    $version = 3;
	}
	elsif ($path =~ m{^/website/}) {
	    $version = 3;
	}
	elsif ($path =~ m{^/dashboard/widgets}) {
	    $version = 3;
	}
	elsif ($path =~ m{^/service/(services|groups)$}) {
	    $version = 1;
	}
	elsif ($path =~ m{^/service/(services|groups)/\d+/properties$}) {
	    $version = 1;
	}
	elsif ($path =~ m{^/device/(devices|groups)/\d+/properties$}) {
	    $version = 1;
	}
	elsif ($path =~ m{^/device/devices/\d+/devicedatasources$}) {
	    $version = 1;
	}
	elsif ($path =~ m{^/setting/collectors(/\d+)?$}) {
	    $version = 1;
	}
	else {
	    $version = 2;
	}
    }

    return $version;
}

# internal method to handle request and return data.
# handles rate-limiting.
sub _do_request {
    my $self = shift;
    my %opts = @_;

    my $raw = 0;
    $raw = $opts{'raw'} if defined $opts{'raw'};

    my $version = $opts{'version'};
    $version ||= 1;
    my $status_field = $version == 1 ? "status" : "errorCode";

    my $req = $opts{request};
    my $url = $opts{url};
    my $timeout = $opts{'timeout'};
    trace(7, "Request: " . localtime . "\n");
    trace(3, "Raw request:\n" . $req->as_string . "\n");
    if ($opts{modifies} and $DRYRUN) {
	warn "LMAPI: DRYRUN -- Request is:\n",
	     "        URL: ", $url, "\n",
	     "    Content: ", $req->content, "\n";
	return({ $status_field => 'OK', message => 'DRYRUN' });
    }

    my $ua = LWP::UserAgent->new();
    $ua->timeout($timeout) if defined $timeout;

    my $retries = 0;
    my $max_retries = 3;  # maybe make this a parameter to _do_request()?
    while (1) {
	#
	# Stash the request object in case we need to dump it later due to errors
	#
	$self->{_last_request} = $req;
	if (my $response = $ua->request( $req )) {
	    if ($response->is_success) {
		if ($retries) {
		    #
		    # use warn instead of carp because we don't
		    # need it to output the caller line number on success.
		    #
		    warn "retry $retries successful!\n";
		}
		trace(7, "Response: " . localtime . "\n");
		trace(9, "response data:\n", $response->content, "\n");
		my $hash = from_json($response->content);
		if ($raw) {
		    $hash->{json} = $response->content;
		}
		if ($version == 1 and not defined $hash->{$status_field}) {
		    $hash->{$status_field} = $response->code;
		}
		return $hash;
	    }
	    elsif ($response->status_line =~ /^429\s/ and $response->header('X-Rate-Limit-Remaining') == 0) {
		my $window = $response->header('X-Rate-Limit-Window');
		if (defined $window and $window > 0) {
		    trace(1, "Sleeping for $window seconds due to rate-limit\n");
		    sleep($window);
		}
	    }
	    elsif ($response->code == 400 or $response->code == 404) {
		# should have response data with more details
		my $content = from_json($response->content);
		if (ref($content) eq 'HASH' and $content->{errmsg}) {
		    return { $status_field => $response->code, errmsg => $content->{errmsg} };
		}
		else {
		    return { $status_field => $response->code, errmsg => $response->status_line };
		}
	    }
	    elsif ($response->status_line =~ /^500\s/ and $response->header("Client-Warning") eq 'Internal response') {
		# An error happened on this side of the connection such as an 
		# alarm timer expiring or other handled signal.  Retry.
		$retries++;
		if ($retries > $max_retries) {
		    carp $self->company, ": Request had LMAPI failure after $max_retries retries -- giving up.\n";
		    return { $status_field => 500, errmsg => $response->status_line };
		}
		else {
		    trace(7, "Internal error received: " . localtime . "\n");
		    carp $self->company, ": Request had internal error -- attempting retry $retries\n";
		    trace(3, "Response as-string:\n" . $response->as_string . "\n");
		    next;
		}
	    }
	    else {
		carp $self->company, ": Problem with request:\n", 
		     "    Request: $url\n", 
		     "    Response Status: ", $response->status_line . "\n",
		     "    Response Content ", $response->content . "\n";
		trace(3, Dumper($response));
		return { $status_field => 500, errmsg => $response->status_line };
	    }
	}
    }

    carp $self->company, ": Problem with request:\n", 
	 "    Request: $url\n", 
	 "    Response Status: TIMEOUT\n";
    return { $status_field => 500, errmsg => "Request timed out" };
}

# internal function.  Makes sure filter expressions are properly URI-encoded.
sub _encode_filter_expr {
    my %opts = @_;
    my $attr = $opts{attr};
    my $expr = $opts{expr};
    #
    # Any '+' characters need to be double-encoded so just replace them
    # with '%252B'
    #
    $expr =~ s/\+/%252B/g;

    #
    # Any '\' characters need to be doubled and encoded so replace them with
    # '%5C%5C'
    #
    $expr =~ s/\\/%5C%5C/g;

    # If we're using API v2 (or later, presumably) any string-type attributes
    # need their expressions to be quoted, so do so unless they are already
    # quoted.  This list will need to be expanded.
    my @string_attrs = qw( displayName fullPath dataPointName instanceDescription );

    STR:
    for my $str (@string_attrs) {
	if ($attr =~ /^$str/) {
	    $expr = qq{"$expr"} unless ($expr =~ /^".*"$/);
	    #
	    # Make sure any special characters (&, -, etc.) get handled.
	    #
	    $expr = uri_escape($expr);
	    last STR;
	}
    }
    return($expr);
}

# internal method, used by get_all to deal with paging
sub _get {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};

    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);
    delete $opts{version};

    # Handle filters separately and try to handle the special cases
    #   see: https://communities.logicmonitor.com/topic/7763-api-filtering-info/
    if ($opts{filter}) {
	my $pre_filter = $opts{filter};
	my $filter;
	if (not defined reftype($pre_filter)) {
	    #
	    # If passed a scalar, assume the caller knows what they're doing and
	    # just use it as-is.  If passed a ref, then handle it specially.
	    #
	    $filter = $pre_filter;
	}
	elsif (reftype($pre_filter) eq 'HASH') {
	    #
	    # If passed as a hashref, the keys should be the attribute and operation 
	    # and the value should be the expression.  For example:
	    #
	    #     { 'cleared:' => 'true', 'displayName~' => 'esxi' }
	    #
	    my @filters = ();
	    for my $attr (sort keys %$pre_filter) {
		my $expr = _encode_filter_expr(attr => $attr, expr => $pre_filter->{$attr});
		push @filters, qq{$attr$expr};
	    }

	    $filter = join(',', @filters);
	}
	elsif (reftype($pre_filter) eq 'ARRAY') {
	    #
	    # If passed as an arrayref, it should be an array of arrayrefs and hashrefs.
	    # The arrayrefs should be 3-element arrays in the order: attribute, operation, expression
	    # The hashrefs should have 3 keys: attr, op and expr.
	    # Both arrayrefs and hashrefs can be included.  For example:
	    #
	    #   [ [ 'cleared', ':', 'true' ], { attr => 'displayName', op => '~', expr => 'esxi' } ]
	    # 
	    my @filters = ();
	    for my $f (@$pre_filter) {
		my $attr = "";
		my $op   = "";
		my $expr = "";
		if (reftype($f) eq 'ARRAY') {
		    ($attr, $op, $expr) = @$f;
		}
		elsif (reftype($f) eq 'HASH') {
		    ($attr, $op, $expr) = @{$f}{'attr', 'op', 'expr'};
		}
		else {
		    # if it's anything else, just use it verbatim.
		    $attr = $f;
		}
		$expr = _encode_filter_expr(attr => $attr, expr => $expr);
		push @filters, qq{$attr$op$expr};
	    }
	    $filter = join(',', @filters);
	}

	push(@args, qq{filter=$filter}) if $filter;
    }
	
    
    for my $prop (qw(size sort fields offset format period datapoints start end)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'GET', %opts);
    
    # setup HTTP agent and headers
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
    my $req = GET $url, @headers;

    return $self->_do_request(%opts, version => $version, request => $req, url => $url);
}

sub put {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};
    my $content = $opts{'content'};

    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);
    delete $opts{version};

    for my $prop (qw(_scope collectorId)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'PUT', %opts);

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

    return $self->_do_request(%opts, version => $version, request => $req, url => $url, modifies => 1);
}

sub post {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};
    my $content = $opts{'content'};
    
    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);
    delete $opts{version};

    for my $prop (qw(_scope collectorId)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'POST', %opts);

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

    return $self->_do_request(%opts, version => $version, request => $req, url => $url, modifies => 1);
}

sub patch {
    my $self = shift;
    my %opts = @_;
    my @args;

    my $path = $opts{'path'};
    my $content = $opts{'content'};
    
    # set explicit version, or implicitly for known v2-only paths
    my $version = $self->_version(%opts);
    delete $opts{version};

    for my $prop (qw(_scope collectorId patchFields)) {
        push(@args, "$prop=$opts{$prop}") if $opts{$prop};
    }

    # construct authorization string
    my $auth = $self->lmapiauth(method => 'PATCH', %opts);

    # setup HTTP agent and headers
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

    return $self->_do_request(%opts, version => $version, request => $req, url => $url, modifies => 1);
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
