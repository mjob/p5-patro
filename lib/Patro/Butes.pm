package Patro::Butes;
use strict;
use warnings;
use Attribute::Handlers;
use Carp;

my %private_wrap;
my %sync_wrap;

sub caller_ok {
    my ($pkg) = @_;
    my $c1 = caller(1);
    return ($c1 && $c1->isa($pkg))
	|| $pkg->isa($c1);
}

sub PatroPrivate : ATTR(CODE) {
    my ($pkg,$sym,$referent,$attr,$data,$phase,$file,$line) = @_;
    my $NAME = *{$sym}{NAME};
    $data //= "";
    $private_wrap{$NAME} = [ $pkg, $referent ];
}

sub Synchronized : ATTR(CODE) {
    my ($pkg,$sym,$referent,$attr,$data,$phase,$file,$line) = @_;
    my $NAME = *{$sym}{NAME};
    $data //= "";
    $sync_wrap{$NAME} = [ $pkg, $referent ];
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

    while (my ($name,$pkgcode) = each %sync_wrap) {
	my ($pkg,$code,@meta) = @$pkgcode;
	no strict 'refs';
	no warnings 'redefine';
	use B::Deparse;
	*{$pkg . '::'. $name} = sub {
	    if (Patro::LeumJelly::isProxyRef(CORE::ref($_[0]))) {
		return Patro::synchronize($_[0],
					  sub { $code->(@_) });
	    } else {
		require Patro::Archy;
		my @r;
		my $mid = "$$-" . threads->tid;
		if (Patro::Archy::plock($_[0],$mid)) {
		    if (wantarray) {
			@r = eval { $code->(@_) };
		    } else {
			@r = eval { scalar $code->(@_) };
		    }
		    Patro::Archy::punlock($_[0],$mid);
		}
		return wantarray ? @r : @r ? $r[-1] : undef;
	    }
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

C<:Synchronized> method attribute to get advisory lock
on a proxy's underlying remote object for duration of a method call

    # Patro server
    use Patro;
    use base 'Patro::Butes';
    my $obj = ThreadSafeObject->new;
    patronize($obj)->to_file('patro.cfg');
    package ThreadSafeObject;
    sub new { ... }
    sub foo :Synchronized { ... }
    sub bar :Synchronized { ... }

    # Patro clients
    use Patro;
    use base 'Patro::Butes';
    sub baz :Synchronized { my($proxy,@args) = @_; ... }

    my $proxy = getProxies('patro.cfg');
    $proxy->foo;        # all of these function calls will
    $proxy->bar;        # lock the reference $obj on the
    baz($proxy,1,2,3);  # server for duration of the function

    

    --- TODO ---

=head1 DESCRIPTION

C<Patro::Butes> provides two otherwise-unrelated attributes
to classes that may be served remotely to proxies
with the C<Patro> framework.

=head2 :PatroPrivate

Marks a method as private to proxies. Proxies that attempt to
call a method with the C<PatroPrivate> will fail with the
same error message as if they tried to call a method that
doesn't exist.

As the SYNOPSIS indicates, it is acceptable to call a method
from a proxy that has downstream calls to Patro-private methods
(see the C<foobar> function in the SYNOPSIS).

=head2 :Synchronized

Executes the method with an advisory lock (see L<Patro::Archy>) on the
first argument of the method call, and releases the lock at
the end of the method. If the first argument to the method is a
C<Patro> proxy object, the underlying remote object on the server
will be locked. Locked references are inaccessible to any other monitor
seeking an advisory lock on the same reference until the lock is
released. See L<Patro/"lock"> and the other functions in
L<Patro/"SYNCHRONIZATION">.

    sub foo :Synchronized {
        CODE
    }

is a convenient shorthand for

    sub foo {
        my @r = ();
        if ( Patro::lock($_[0]) ) {
            @r = eval { wantarray ? CODE : scalar CODE };
            Patro::unlock($_[0]);
        }
        die $@ if $@;
        return @r;
    }

=cut
