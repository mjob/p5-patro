use Test::More;
use Carp 'verbose';
use Patro ':test';
use 5.012;
use Scalar::Util 'reftype';

my $r0 = [ 1, 2, 3, 4 ];

ok($r0 && ref($r0) eq 'ARRAY', 'created remote var');

my $cfg = patronize($r0);
ok($cfg, 'got config for patronize array ref');

my ($r1) = Patro->new($cfg)->getProxies;

ok($r1, 'client as boolean');
is(CORE::ref($r1), 'Patro::N1', 'client ref');

is(Patro::ref($r1), 'ARRAY', 'remote ref');
is(Patro::reftype($r1), 'ARRAY', 'remote reftype');

is($r1->[3], 4, 'array access');

push @$r1, [15,16,17], 18;
is($r1->[-3], 4, 'push to remote array');

$r1->[2] = 19;
is($r1->[2], 19, 'set remote array');

is(shift @$r1, 1, 'shift from remote array');

unshift @$r1, (25 .. 31);
is($r1->[6], 31, 'unshift to remote array');
is($r1->[7], 2, 'unshift to remote array');

is(pop @$r1, 18, 'pop from remote array');

my $r6 = $r1->[10];
is(CORE::ref($r6), 'Patro::N1', 'proxy handle for nested remote obj');
is(Patro::ref($r6), 'ARRAY', 'got remote ref type');

done_testing;
