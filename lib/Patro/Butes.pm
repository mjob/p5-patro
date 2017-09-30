package Patro::Butes;
use strict;
use warnings;
use Attribute::Handlers;
use Carp;

my %private_wrap;

sub caller_ok {
    my ($pkg) = @_;
    my $c1 = caller(1);
    #return $c1 && $c1 ne 'Patro::Server';
    return ($c1 && $c1->isa($pkg)) || $pkg->isa($c1);
}

sub PatroPrivate : ATTR(CODE) {
    my ($pkg,$sym,$referent,$attr,$data,$phase,$file,$line) = @_;
    my $NAME = *{$sym}{NAME};
    $data //= "";
    $private_wrap{$NAME} = [ $pkg, $referent ];
}

INIT {
    while (my ($name,$pkgcode) = each %private_wrap) {
	my ($pkg,$code) = @$pkgcode;
	no strict 'refs';
	no warnings 'redefine';
	*{$pkg . '::' . $name} = sub {
	    if ($Patro::ProhibitPrivate && !caller_ok($pkg)) {
		croak "Can't locate object method \"$name\" ",
		      "via package \"$pkg\"";
	    }
	    local $Patro::ProhibitPrivate = 0;
	    return $code->(@_);
	};
    }
}

1;


=head1 NAME

Patro::Butes - attributes for Patro distribution

=head1 SYNOPSIS

C<:PatroPrivate> method attribute, to make a method
inaccessible (private) to a proxy

    # Patro server
    use Patro;
    use base 'Patro::Butes';
    $foo = Foo->new(foo => 123, bar => 456);
    patronize($foo)->to_file('patro.cfg');
    # ...
    package Foo;
    sub new { bless { @_ }, shift }
    sub foo { $_[0]->{foo} }                 # "public" method
    sub bar :PatroPrivate { $_[0]->{bar} }   # "private" method
    sub foobar { $_[0]->bar }                # public api to private function

    # Patro client
    my $proxy = getProxies('patro.cfg');
    $x = $proxy->foo;                    # "123"
    $y = $proxy->foobar;                 # "456"
    $z = $proxy->bar;                    # throws exception

C<:synchronized> method attribute to get advisory lock
on a proxy's underlying remote object for duration of a method call

    # Patro server

    --- TODO ---

=head1 DESCRIPTION

C<Patro::Butes> provides two otherwise-unrelated attributes
to classes that may be served remotely to proxies
with the C<Patro> framework.

=head2 :PatroPrivate

As the SYNOPSIS indicates, it is acceptable to call a method
from a proxy that has downstream calls to Patro-private methods
(see the C<foobar> function in the SYNOPSIS).

=head2 :synchronized



=cut
