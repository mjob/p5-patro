package Patro::LeumJelly;
use strict;
use warnings;
use Data::Dumper;
use Carp;
use Storable;
use MIME::Base64 ();

our $VERSION = '0.12';

sub isProxyRef {
    my ($pkg) = @_;
    return $pkg eq 'Patro::N1' || $pkg eq 'Patro::N2' || $pkg eq 'Patro::N3';
}

sub handle {
    my ($proxy) = @_;
    if (CORE::ref($proxy) eq 'Patro::N2') {
	return $proxy;
    } else {
	return ${$proxy};
    }
}

sub serialize {
    return MIME::Base64::encode_base64( 
	Storable::freeze( $_[0] ), "");
}

sub deserialize {
    if ($Patro::SERVER_VERSION && $Patro::SERVER_VERSION <= 0.10) {
	# Data::Dumper was used before v0.11
	my $VAR1;
	eval $_[0];
	$VAR1;
    } else {
	return Storable::thaw(
	    MIME::Base64::decode_base64($_[0]));
    }
}

# return a Patro::N1 or Patro::N2 object appropriate for the
# object metadata (containing id, ref, reftype values) and client.
sub getproxy {
    my ($objdata,$client) = @_;
    croak "getproxy: insufficient metadata to construct proxy"
	unless $objdata->{id} && $objdata->{ref} && $objdata->{reftype};
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

    if ($proxy->{reftype} eq 'CODE' ||
	$proxy->{reftype} eq 'CODE*') {
	require Patro::N3;
	$proxy->{sub} = sub {
	    return proxy_request( $proxy,
	        {
		    context => defined(wantarray) ? 1 + wantarray : 0,
		    topic => 'CODE',
		    has_args => @_ > 0,
		    args => [ @_ ],
		    command => 'invoke',
		    id => $proxy->{id}
		} );
	};
	return bless \$proxy, 'Patro::N3';
    }

    croak "unsupported remote object reftype '$objdata->{reftype}'";
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

    if ($request->{has_args}) {
	# if there are any Patro'N items in $request->{args},
	# we should convert it to ... what?
	foreach my $arg (@{$request->{args}}) {
	    if (isProxyRef(ref($arg))) {
		my $id = handle($arg)->{id};
		$arg = bless \$id, '.Patroon';
	    }
	}
    }

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
    if ($meta->{$id}) {
	return $client->{proxies}{$id} = getproxy($meta->{$id}, $client);
    } elsif (defined $client->{proxies}{$id}) {
	return $client->{proxies}{$id};
    }
    warn "depatrol: reference $id $obj is not referred to in meta";
    return $obj;
}

# overload handling for Patro::N1 and Patro::N2

my %numeric_ops = map { $_ => 1 }
qw# + - * / % ** << >> += -= *= /= %= **= <<= >>= <=> < <= > >= == != ^ ^=
    & &= | |= neg ! not ~ ++ -- atan2 cos sin exp abs log sqrt int 0+ #;

# non-numeric ops:
#  x . x= .= cmp lt le gt ge eq ne ^. ^.= ~. "" qr -X ~~

sub overload_handler {
    my ($ref, $y, $swap, $op) = @_;
    my $handle = handle($ref);
    my $overloads = $handle->{overloads};
    if ($overloads && $overloads->{$op}) {
	# operation is overloaded in the remote object.
	# ask the server to compute the operation result
	return proxy_request( $handle,
	    { id => $handle->{id},
	      topic => 'OVERLOAD',
	      command => $op,
	      has_args => 1,
	      args => [$y, $swap] } );
    }

    # operation is not overloaded on the server.
    # Do something sensible.
    return 1 if $op eq 'bool';
    return if $op eq '<>';  # nothing sensible to do for this op
    my $str = overload::StrVal($ref);
    if ($numeric_ops{$op}) {
	my $num = hex($str =~ /x(\w+)/);
	return $num if $op eq '0+';
	return cos($num) if $op eq 'cos';
	return sin($num) if $op eq 'sin';
	return exp($num) if $op eq 'exp';
	return log($num) if $op eq 'log';
	return sqrt($num) if $op eq 'sqrt';
	return int($num) if $op eq 'int';
	return abs($num) if $op eq 'abs';
	return -$num if $op eq 'neg';
	return $num+1 if $op eq '++';
	return $num-1 if $op eq '--';
	return !$num if $op eq '!' || $op eq 'not';
	return ~$num if $op eq '~';

	# binary op
	($num,$y)=($y,$num) if $swap;
	return atan2($num,$y) if $op eq 'atan2';
	return $ref if $op eq '=' || $op =~ /^[^<=>]=/;
	return eval "$num $op \$y";
    }

    # string operation
    return $str if $op eq '""';
    return $ref if $op eq '=' || $op =~ /^[^<=>]=/;
    return qr/$str/ if $op eq 'qr';
    return eval "-$y \$str" if $op eq '-X';
    ($str,$y) = ($y,$str) if $swap;
    return eval "\$str $op \$y";
}

######################################################################
#
# useful edits and extensions to threads::shared
#
# 1. support splice on shared arrays
# 2. support CODE refs in shared data structures
# 3. support GLOB refs in shared data structures
#

our $_extended = 0;
our $share_code;
our $share_glob;
our $make_shared;

sub extend_threads_shared {
    no warnings 'redefine';
    if ($_extended++) {
#	carp "Patro::LeumJelly::extend_threads_shared called again!";
#	return;
    }
    if (!defined &share_orig) {
	*share_orig = \&threads::shared::share;
    }
    *threads::shared::shared_clone = \&Patro::LeumJelly::_shared_clone;
    *threads::shared::share = \&Patro::LeumJelly::_share;
    *threads::shared::tie::SPLICE = \&Patro::LeumJelly::threads_shared_tie_SPLICE;
    $share_code = 1;
    $share_glob = 1;
}

sub threads_shared_tie_SPLICE {
    use B;
    my ($tied,$off,$len,@list) = @_;
    my @bav = B::AV::ARRAY($tied);
    my $arraylen = 0 + @bav;
    if ($off < 0) {
	$off += $arraylen;
	if ($off < 0) {
	    croak "Modification of non-createable array value attempated, ",
		"subscript $_[1]";
	}
    }
    if (!defined $len || $len eq 'undef') {
	$len = $arraylen - $off;
    }
    if ($len < 0) {
	$len += $arraylen - $off;
	if ($len < 0) {
	    $len = 0;
	}
    }

    my (@tmp, @val);
    for (my $i=0; $i<$off; $i++) {
	my $fetched = $bav[$i]->object_2svref;
	push @tmp, $$fetched;
    }
    for (my $i=0; $i<$len; $i++) {
	my $fetched = $bav[$i+$off]->object_2svref;
	push @val, $$fetched;
    }
    push @tmp, map { _shared_clone($_) } @list;
    for (my $i=$off+$len; $i<$arraylen; $i++) {
	my $fetched = $bav[$i]->object_2svref;
	push @tmp, $$fetched;
    }

    # is there a better way to clear the array?
    $tied->POP for 0..$arraylen;
    $tied->PUSH(@tmp);
    return @val;
}

sub _share (\[$@%]) {
    if (ref($_[0]) eq 'CODE' && $share_code) {
	return $_[0] = threadsx::shared::code->new( $_[0] );
    } elsif (ref($_[0]) eq 'GLOB' && $share_glob) {
	return $_[0] = threadsx::shared::glob->new( $_[0] );
    } elsif (ref($_[0]) eq 'REF') {
	if (ref(${$_[0]}) eq 'CODE' && $share_code) {
	    return $_[0] = threadsx::shared::code->new( ${$_[0]} );
	} elsif (ref(${$_[0]}) eq 'GLOB' && $share_glob) {
	    return $_[0] = threadsx::shared::glob->new( ${$_[0]} );
	}
    }
    share_orig( $_[0] );
}

*_shared_clone = sub {
    return $make_shared->(shift, {});
};


# copied from threads::shared 1.48
$make_shared = sub {
    package
	threads::shared;
    use Scalar::Util qw(reftype refaddr blessed);
    my ($item,$cloned) = @_;
    return $item if (!ref($item) || threads::shared::is_shared($item)
		     || !$threads::threads);
    my $addr = refaddr($item);
    return $cloned->{$addr} if exists $cloned->{$addr};
    my ($ref_type,$copy) = reftype($item);
    if ($ref_type eq 'ARRAY') {
	$copy = &threads::shared::share( [] );
	$cloned->{$addr} = $copy;
	push @$copy, map { $make_shared->($_,$cloned) } @$item;
    } elsif ($ref_type eq 'HASH') {
	my $ccc = {};
	$copy = &threads::shared::share( $ccc );
	$cloned->{$addr} = $copy;
	while (my ($k,$v) = each %$item) {
	    $copy->{$k} = $make_shared->($v,$cloned);
	}
    } elsif ($ref_type eq 'SCALAR') {
	$copy = \do{ my $scalar = $$item };
	threads::shared::share($copy);
	$cloned->{$addr} = $copy;
    } elsif ($ref_type eq 'REF') {
	if ($addr == refaddr($$item)) {
	    $copy = \$copy;
	    threads::shared::share($copy);
	    $cloned->{$addr} = $copy;
	} else {
	    my $tmp;
	    $copy = \$tmp;
	    threads::shared::share($copy);
	    $cloned->{$addr} = $copy;
	    $tmp = $make_shared->($$item,$cloned);
	}
    } elsif ($ref_type eq 'CODE') {
	$copy = $cloned->{$addr} = threadsx::shared::code->new($item);
    } elsif ($ref_type eq 'GLOB') {
	$copy = $cloned->{$addr} = threadsx::shared::code->new($item);
    } else {
	require Carp;
	if (! defined $threads::shared::clone_warn) {
	    Carp::croak("Unsupported ref type: ", $ref_type);
	} elsif ($threads::shared::clone_warn) {
	    Carp::carp("Unsupported ref type: ", $ref_type);
	}
	return undef;   
    }

    # If input item is an object, then bless the copy into the same class
    if (my $class = blessed($item)) {
        CORE::bless($copy, $class);
    }

    # Clone READONLY flag
    if ($ref_type eq 'SCALAR') {
        if (Internals::SvREADONLY($$item)) {
            Internals::SvREADONLY($$copy, 1) if ($] >= 5.008003);
        }
    }
    if (Internals::SvREADONLY($item)) {
        Internals::SvREADONLY($copy, 1) if ($] >= 5.008003);
    }

    return $copy;
};

package
    threadsx::shared::code;
use overload fallback => 1, '&{}' => 'code';
use Carp;
our %CODE_LOOKUP;
sub new {
    my ($pkg,$ref) = @_;
    if (ref($ref) eq $pkg) {
	carp "threadsx::shared::code: ref is already shareable code";
	return $ref;
    } elsif (ref($ref) ne 'CODE') {
	croak "usage: $pkg->new(CODE)";
    }
    my $id = Scalar::Util::refaddr($ref);
    $CODE_LOOKUP{$id} //= $ref;
    threads::shared::shared_clone(CORE::bless \$id, $pkg);
}
sub code {
    return $CODE_LOOKUP{${$_[0]}} || 
	sub { croak "threadsx::shared::code: bad ",__PACKAGE__," id ${$_[0]}" };
}

package
    threadsx::shared::glob;
use overload fallback => 1, '*{}' => 'glob';
use Carp;
our %GLOB_LOOKUP;
sub new {
    my ($pkg,$ref) = @_;
    if (ref($ref) eq $pkg) {
	carp "threadsx::shared::glob: ref is already shareable glob";
	return $ref;
    } elsif (ref($ref) ne 'GLOB') {
	croak "usage: $pkg->new(GLOB)";
    }
    my $id = Scalar::Util::refaddr($ref);
    $GLOB_LOOKUP{$id} //= $ref;
    threads::shared::shared_clone(CORE::bless \$id, $pkg);
}
sub glob { return $GLOB_LOOKUP{${$_[0]}} || *STDERR }

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
