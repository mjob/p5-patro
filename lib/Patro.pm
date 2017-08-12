package Patro;
use strict;
use warnings;
use Patro::LeumJelly;
use Scalar::Util;
use Data::Dumper;
use Socket ();
use Carp;
use base 'Exporter';
our @EXPORT = qw(patronize getProxies);

our $VERSION = '0.10';

sub import {
    my ($class, @args) = @_;
    my @tags = grep /^:/, @args;
    @args = grep !/^:/, @args;
    foreach my $tag (@tags) {
	if ($tag eq ':test') {
	    require Patro::Server;
	    Patro::Server->TEST_MODE;
	    # some tests will check if the remote object has changed
	    # after being manipulated by the proxy. This can only
	    # happen with a threaded server (or with certain objects
	    # that do not maintain state in local memory), so we should
	    # skip those tests if we are using the forked server.
	    *ok_threaded = sub {
		if ($Patro::Server::threads_avail) {
		    goto &Test::More::ok;
		} else {
		    Test::More::ok(1, $_[1] ? "$_[1] - SKIPPED" :
		       "skip test that requires threaded server");
		}
	    };
	    push @EXPORT, 'ok_threaded';
	}
    }
    Patro->export_to_level(1, 'Patro', @args, @EXPORT);
}

# make Patro::nize a synonym for patronize
sub nize { goto &patronize }

sub patronize {
    croak 'usage: Patro::patronize(@refs)' if @_ == 0;
    require Patro::Server;
    my $server = Patro::Server->new({}, @_);
    return $server->{config};
}

sub ref {
    my $ref = CORE::ref($_[0]);
    if (!Patro::LeumJelly::isProxyRef($ref)) {
	return $ref;
    }
    my $handle = Patro::LeumJelly::handle($_[0]);
    return $handle->{ref};
}

sub reftype {
    my $ref = CORE::ref($_[0]);
    if (!Patro::LeumJelly::isProxyRef($ref)) {
	return Scalar::Util::reftype($_[0]);
    }
    my $handle = Patro::LeumJelly::handle($_[0]);
    return $handle->{reftype};
}

sub client {
    if (!Patro::LeumJelly::isProxyRef(CORE::ref($_[0]))) {
	return;     # not a remote proxy object
    }
    return Patro::LeumJelly::handle($_[0])->{client};
}

sub main::xdiag {
    if ($INC{'Test/More.pm'}) {
	my @lt = localtime;
	my $lt = sprintf "%02d:%02d:%02d", @lt[2,1,0];
	my $pid = $$;
	if ($Patro::Server::threads_avail) {
	    $pid .= "-" . threads->tid;
	}
	Test::More::diag("xdiag $pid $lt: ",
	    map { CORE::ref($_) ? Data::Dumper::Dumper($_) : $_ } @_ );
    } else {
	print STDERR "ZZZZZ ", Data::Dumper::Dumper(@_);
    }
}

# Patro OO-interface

sub new {
    my ($pkg,$config) = @_;
    croak __PACKAGE__,": no host" unless $config->{host};
    croak __PACKAGE__,": no port" unless $config->{port};

    my $iaddr = Socket::inet_aton($config->{host});
    my $paddr = Socket::pack_sockaddr_in($config->{port}, $iaddr);

    socket(my $socket, Socket::PF_INET(), Socket::SOCK_STREAM(),
	   getprotobyname("tcp")) or croak __PACKAGE__,": socket $!";
    connect($socket,$paddr) 
	or croak(__PACKAGE__, ": connect to $config->{host}:$config->{port}",
		 " failed: $!");

    my $self = bless {
	config => $config,
	socket => $socket,
	proxies => {},
	objs => [],
    }, $pkg;

    my $fh0 = select $socket;
    $| = 1;
    select $fh0;

    foreach my $odata (@{$config->{store}}) {
	my $proxyref = Patro::LeumJelly::getproxy($odata,$self);
	$self->{proxies}{$odata->{id}} = $proxyref;
	push @{$self->{objs}}, $proxyref;
    }
    return $self;
}

sub getProxies {
    my $patro = shift;
    if (CORE::ref($patro) eq 'HASH') {
	# arg to getProxies is config hash, not Patro object
	my $cfg = $patro;
	$patro = Patro->new($cfg);
    }
    return @{$patro->{objs}};
}


1;

=head1 NAME

Patro - proxy access to remote objects

=head1 VERSION

0.10

=head1 SYNOPSIS

    # on machine 1 (server)
    use Patro;
    my $obj = ...
    $config = patronize($obj);
    open my $fh, '>config_file'; print $fh $config; close $fh;


    # on machines 2 through n (clients)
    use Patro;
    open my $fh, '<config_file'; my $config=<$fh>; close $fh;
    my ($proxy) = Patro->new($config)->getProxies;
    ...
    $proxy->{key} = $val;         # updates $obj->{key} for obj on server
    $val = $proxy->method(@args); # calls $obj->method for obj on server


=head1 DESCRIPTION

C<Patro> is a mechanism for making any Perl reference in one Perl program
accessible is other processes, even processes running on different hosts.
The "proxy" references have the same look and feel as the native references
in the original process, and any manipulation of the proxy reference
will have an effect on the original reference.

=head2 Some important features:

=over 4

=item * Hash members and array elements

Accessing or updating hash values or array values on a remote reference
is done with the same syntax as with the local reference:

    # host 1
    use Patro;
    my $hash1 = { abc => 123, def => [ 456, { ghi => "jkl" }, "mno" ] };
    my $config = patronize($hash1);
    ...

    # host 2
    use Patro;
    my $hash2 = Patro->new($config)->getProxies;
    print $hash2->{abc};                # "123"
    $hash2->{def}[2] = "pqr";           # updates $hash1 on host 1
    print delete $hash2->{def}[1]{ghi}; # "jkl", updates $hash1 on host1

=item * Remote method calls

Method calls on the proxy object are propagated to the original object,
affecting the remote object and returning the result of the call.

    # host 1
    use Patro;
    sub Foofie::new { bless \$_[1],'Foofie' }
    sub Foofie::blerp { my $self=shift; wantarray ? (5,6,7,$$self) : ++$$self }
    $config = patronize(Foofie->new(17));
    ...

    # host 2
    use Patro;
    my $foo = Patro->new($config)->getProxies;
    my @x = $foo->blerp;           # (5,6,7,17)
    my $x = $foo->blerp;           # 18

=item * Overloaded operators

Any overloaded operations on the original object are supported on the
remote object.

    # host 1
    use Patro;
    my $obj = Barfie->new(2,5);
    $config = patronize($obj);
    package Barfie;
    use overload '+=' => sub { $_ += $_[1] for @{$_[0]->{vals}};$_[0] },
         fallback => 1;
    sub new {
        my $pkg = shift;
        bless { vals => [ @_ ] }, $pkg;
    }
    sub prod { my $self = shift; my $z=1; $z*=$_ for @{$_[0]->{vals}}; $z }

    # host 2
    use Patro;'
    my $proxy = getProxies($config);
    print $proxy->prod;      # calls Barfie::prod($obj) on host1, 2 * 5 => 10
    $proxy += 4;             # calls Barfie '+=' sub on host1
    print $proxy->prod;      # 6 * 9 => 54

=back

=head1 FUNCTIONS

=head2 patronize

    CONFIG = patronize(@REFS)

Creates a server on the local machine that provides proxy access to
the given list of references. It returns a string (some `Data::Dumper`
output) with information about how to connect to the server. The output
can be used as input to the `getProxies()` function to retrieve
proxies to the shared references.

=head2 getProxies

    PROXIES = getProxies(CONFIG)

Connects to a server on another machine, specified in the `CONFIG`
string, and returns proxies to the list of references that are served.

=head2 ref

    TYPE = Patro::ref(PROXY)

For the given proxy object, returns the ref type of the remote object
being served. If the input is not a proxy, returns C<undef>.
See also L<"reftype">.

=head2 reftype

    TYPE = Patro::reftype(PROXY)

Returns the simple reference type (e.g., C<ARRAY>) of the remote
object associated with the given proxy, as if we were calling
C<Scalar::Util::reftype> on the remote object. Returns C<undef> if
the input is not a proxy object.

=head2 client

    CLIENT = Patro::client(PROXY)

Returns the IPC client object used by the given proxy to communicate
with the remote object server. The client object contains information
about how to communicate with the server and other connection 
configuration.

=head1 ENVIRONMENT

C<Patro> pays attention to the following environment variables.

=head2 PATRO_THREADS

If the environment variable C<PATRO_THREADS> is set, C<Patro> will use
it to determine whether to use a forked server or a threaded server
to provide proxy access to objects. If this variable is not set,
C<Patro> will use threads if the L<threads> module can be loaded.

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
