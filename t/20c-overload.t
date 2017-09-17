use Test::More;
use Patro ':test', ':paranoid';
use strict;
use warnings;

# what about HASH-type objects that overload '@{}'?
# ... that overload %{}?

diag "HASH-type reference";
my $r1 = Hashem->new;

ok($r1->{quux} == 42, 'hash deref 1');
ok($r1->[2] == 9, 'array deref 1');
$r1->[3] = 11;
ok($r1->[3] == 11, 'array deref and update');
ok(!defined($r1->{abc}), 'hash deref 2');
$r1->set_key("bar");
ok($r1->{abc} == 123, 'hash deref 3');
ok(!defined($r1->{quux}), 'hash deref 4');
$r1->{quux} = 19;
ok($r1->{quux} == 19, 'hash deref and update');
$r1->set_key("foo");
ok($r1->{quux} == 42, 'hash deref 5');

$r1 = Hashem->new;


my ($p1) = getProxies(patronize($r1));
ok($p1, 'got proxy Hashem');

diag "HASH-type reference as proxy";
is(Patro::ref($p1), 'Hashem', 'proxy has correct ref');
is(Patro::reftype($p1),'HASH', 'proxy has correct reftype');

ok($p1->{quux} == 42, 'hash deref 1 over proxy');
ok($p1->[2] == 9, 'array deref 1 over proxy');
$p1->[3] = 11;
ok($p1->[3] == 11, 'array deref and update over proxy');
ok(!defined($p1->{abc}), 'hash deref 2 over proxy');
$p1->set_key("bar");
ok($p1->{abc} == 123, 'hash deref 3 over proxy');
ok(!defined($p1->{quux}), 'hash deref 4 over proxy');
$p1->{quux} = 19;
ok($p1->{quux} == 19, 'hash deref and update over proxy');
$p1->set_key("foo");
ok($p1->{quux} == 42, 'hash deref 5 over proxy');

done_testing;




package Hashem;
# a HASH-type object that overloads HASH and ARRAY derefence operators
use overload
    '%{}' => sub { my $y = Hhash_deref(@_); return $y; },
    '@{}' => 'Harray_deref',
    bool => sub{1};
sub new {
    my $hash = { foo => { quux => 42 }, bar => { abc => 123, def => 456 },
		 baz => [7, 8, 9], __key__ => 'foo' };
    bless $hash, __PACKAGE__;
}
sub Harray_deref {
    my $self = shift;
    no overloading '%{}';
    my $ref = $self->{baz};
    return $ref;
}
sub Hhash_deref {
    my $self = shift;
    no overloading;
    my $key = $self->{__key__};
    my $ref = $self->{$key};
    return $ref;
}
sub set_key {
    my $self = shift;
    no overloading;
    $self->{__key__} = shift;
    return;
}
