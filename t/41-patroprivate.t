use strict;
use warnings;
use Test::More;
use Patro ':test';

our $fo = Foo->new(foo => 123, bar => 456);
our ($foo) = getProxies(patronize($fo));

ok($foo, 'made new Foo');
is(eval { $foo->foo }, 123, 'Foo::foo call ok');
is($@, '', 'Foo::foo did not throw');

is(eval { $foo->bar }, undef, 'Foo:bar call failed');
ok($@, 'Foo::bar throws when prohibition on');
my $e1 = $@;
$e1 =~ s/ at .*//;

is(eval { $foo->foobar }, 456, 'Foo::foobar call ok');
is($@, '', 'Foo::foobar did not throw');

is(eval { $main::foo->bog }, undef, 'Calling missing Foo method fails');
ok($@, 'Foo::bogus throws');
my $e2 = $@;
$e2 =~ s/bog/bar/;
$e2 =~ s/ at .*//;
is($e1,$e2, 'error messages similar for bogus,private method calls');

done_testing;


package Foo;
use base 'Patro::Butes';
no warnings 'reserved';

sub new { my ($pkg,@list) = @_; bless { @list }, $pkg }
sub foo               { $_[0]->{foo} }  # public
sub bar :PatroPrivate { $_[0]->{bar} }  # private
sub foobar            { $_[0]->bar }    # public that calls private
      
