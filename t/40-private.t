use strict;
use warnings;
use Test::More;

our $foo = Foo->new(foo => 123, bar => 456);
ok($foo, 'made new Foo');
is(eval { $foo->foo }, 123, 'Foo::foo call ok');
is($@, '', 'Foo::foo did not throw');

{
    local $Patro::ProhibitPrivate = 0;
    is(eval { $foo->bar }, 456, 'Foo::bar call ok');
    is($@, '', 'Foo::bar did not throw when prohibition off');

    is(eval { $foo->foobar }, 456, 'Foo::foobar call ok');
    is($@, '', 'Foo::foobar did not throw');
}

{
    local $Patro::ProhibitPrivate = 1;
    is(eval { $foo->bar }, undef, 'Foo:bar call failed');
    ok($@, 'Foo::bar throws when prohibition on');

    is(eval { $foo->foobar }, 456, 'Foo::foobar call ok');
    is($@, '', 'Foo::foobar did not throw');
}

{
    package Bar;
    use Test::More;
    local $Patro::ProhibitPrivate = 1;

    is(eval { $main::foo->bog }, undef, 'Calling missing Foo method fails');
    ok($@, 'Foo::bogus throws');
    is(eval { $main::foo->bar }, undef, 'Foo::bar fails with prohibition');
    ok($@, 'Foo::bar threw');

    is(eval { $main::foo->foobar }, 456, 'Foo::foobar ok with prohibition');
    is($@, '', 'Foo::foobar did not throw');
}

{
    package Baz;
    our @ISA = qw(Foo);
    use Test::More;

    ok(__PACKAGE__->isa('Foo'), 'current pkg is subclass');

    local $Patro::ProhibitPrivate = 1;
    is( eval { $main::foo->bar }, 456, 'Foo::bar ok from subclass');
    ok(!$@, 'Foo::bar did not throw');

    is( eval { $main::foo->foobar }, 456, 'Foo::foobar ok');
    is($@, '', 'Foo::foobar did not throw');
}

{
    package Quux;
    use Test::More;

    ok('Foo'->isa(__PACKAGE__), 'current pkg is superclass');

    local $Patro::ProhibitPrivate = 1;
    is (eval { $main::foo->bar }, 456, 'Foo::bar ok from superclass');
    ok(!$@, 'Foo::bar did not throw');

    is(eval { $main::foo->foobar }, 456, 'Foo::foobar ok with prohibition');
    is($@, '', 'Foo::foobar did not throw');
    
}

done_testing;



package Foo;
use base 'Patro::Butes';
BEGIN { push @Foo::ISA, 'Quux' }

sub new { my ($pkg,@list) = @_; bless { @list }, $pkg }
sub foo               { $_[0]->{foo} }  # public
sub bar :PatroPrivate { $_[0]->{bar} }  # private
sub foobar            { $_[0]->bar }    # public that calls private
      
