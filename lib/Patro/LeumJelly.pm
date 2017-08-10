package Patro::LeumJelly;
use strict;
use warnings;
use Data::Dumper;
use Carp;

our $VERSION = '0.10';

sub isProxyRef {
    my ($pkg) = @_;
    return $pkg eq 'Patro::N1' || $pkg eq 'Patro::N2';
}

sub handle {
    my ($proxy) = @_;
    if (CORE::ref($proxy) eq 'Patro::N1') {
	return ${$proxy};
    } else {
	return $proxy;
    }
}

sub serialize {
    local $Data::Dumper::Useqq = 1;
    local $Data::Dumper::Indent = 0;
    local $Data::Dumper::Purity = 1;
    my $dump = Data::Dumper::Dumper( $_[0] );
    chomp($dump);
    return $dump;
}

sub deserialize {
    my $VAR1;
    eval $_[0];
    $VAR1;
}

# return a Patro::N1 or Patro::N2 object appropriate for the
# object metadata (containing id, ref, reftype values) and client.
sub getproxy {
    my ($objdata,$client) = @_;
    croak unless $objdata->{id} && $objdata->{ref} && $objdata->{reftype};
    my $proxy = { %$objdata };
    if ($objdata->{overload}) {
	$proxy->{overloads} = { map {; $_ => 1 } @{$objdata->{overload}} };
    }
    $proxy->{client} = $client;
    $proxy->{socket} = $client->{socket};
    if ($proxy->{reftype} eq 'SCALAR') {
	require Patro::N2;
	tie my $s, 'Patro::Tie::SCALAR', $proxy;
	$proxy->{scalar} = \$s;
	return bless $proxy, 'Patro::N2';
    }

    if ($proxy->{reftype} eq 'ARRAY') {
	require Patro::N1;
	tie my @a, 'Patro::Tie::ARRAY', $proxy;
	$proxy->{array} = \@a;
	return bless \$proxy, 'Patro::N1';
    }

    if ($proxy->{reftype} eq 'HASH') {
	require Patro::N1;
	tie my %h, 'Patro::Tie::HASH', $proxy;
	$proxy->{hash} = \%h;
	return bless \$proxy, 'Patro::N1';
    }

    croak "unsupported remote object reftype '$objdata->{reftype}'";
}

sub overload_handler {
    return $_[0];
}

# make a request through a Patro::N's client, return the response
sub proxy_request {
    my ($proxy,$request) = @_;
    my $socket = $proxy->{socket};
    if (!defined $request->{context}) {
	$request->{context} = defined(wantarray) ? 1 + wantarray : 0;
    }
    if (!defined $request->{id}) {
	$request->{id} = $proxy->{id};
    }

    ### unwind_args($request);

    my $sreq = serialize($request);
    my $resp;
    if ($proxy->{_DESTROY}) {
	no warnings 'closed';
	print {$socket} $sreq . "\n";
	$resp = readline($socket);
    } else {
	print {$socket} $sreq . "\n";
	$resp = readline($socket);
    }
    if (!defined $resp) {
	return serialize({context => 0, response => ""});
    }
    croak if ref($resp);
    $resp = deserialize_response($resp, $proxy->{client});
    if ($resp->{error}) {
	croak $resp->{error};
    }
    if (exists $resp->{disconnect_ok}) {
	return $resp;
    }
    if ($resp->{context} == 0) {
	return;
    }
    if ($resp->{context} == 1) {
	return $resp->{response};
    }
    if ($resp->{context} == 2) {
	if ($request->{context} == 2) {
	    return @{$resp->{response}};
	} else {
	    return $resp->{response}[0];
	}
    }
    croak "invalid response context";
}

sub deserialize_response {
    my ($response,$client) = @_;
    $response = deserialize($response);

    # Does the response contain SCALAR references?
    # Does the response have meta information for these
    # dereferenced SCALAR values?
    # Then they must be converted to Patro::Nx objects.

    if ($response->{context}) {
	if ($response->{context} == 1) {
	    $response->{response} = depatrol($client,
					     $response->{response},
					     $response->{meta})
	} elsif ($response->{context} == 2) {
	    $response->{response} = [ map depatrol($client,
						   $_, $response->{meta}),
				      @{$response->{response}} ];
	}
    }
    return $response;
}

sub depatrol {
    my ($client, $obj, $meta) = @_;
    if (ref($obj) ne 'SCALAR') {
	return $obj;
    }
    my $id = $$obj;
    if (!$meta->{$id}) {
	warn "depatrol: reference $obj is not referred to in meta";
	return $obj;
    }
    return getproxy($meta->{$id}, $client);
}

1;

=head1 NAME

Patro::LeumJelly - functions that make Patro easier to use

=head1 DESCRIPTION

A collection of functions useful for the L<Patro> distribution.
This package is for internal functions that are not of general
interest to the users of L<Patro>.

=head1 LICENSE AND COPYRIGHT

MIT License

Copyright (c) 2017, Marty O'Brien

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
