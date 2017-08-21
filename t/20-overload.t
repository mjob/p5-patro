use Test::More;
use Patro ':test';
use strict;
use warnings;

if (!eval "use Math::BigInt;1") {
    ok(1,"SKIP - Math::BigInt not available");
    done_testing();
    exit;
}

my $b0 = Math::BigInt->new(42);
my $b1 = Math::BigInt->new(19);
my $cfg = patronize($b0,$b1);
ok($cfg, "got config for two Math::BigInt's");
   
my ($p0,$p1) = Patro->new($cfg)->getProxies;
ok($p0 && $p1, "got proxies");

# !!! ok($p0+$p1==61,...) works, but
#     is($p0+$p1,61,...) compares 61 with "Patro::N1=REF(...)"
ok($p0 + $p1 == 42 + 19, 'proxy operation');
is("" . ($p0 * $p1), 42 * 19, "proxy operation");
ok($p0 * $p1 == 42 * 19, 'proxy operation');
ok($p0 / $p1 == int(42/19), 'operation on proxy integers respects int');

# this test doesn't work on threaded server - "Splice not implemented for
#    shared arrays ..."
my $p2 = eval { $p1->bfac };
is($p2, $b1->bfac, 'proxy method call');

done_testing;
