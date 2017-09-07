use Test::More;
use Patro ':test';
use Scalar::Util 'reftype';
use 5.010;

sub foo::sqr { $_[1] *= $_[1] ; 23 };

sub sqr { $_[0] *= $_[0]; 19 }

my $c1 = \&sqr;
my $c2 = bless {}, 'foo';
my ($p1,$p2) = Patro->new( patronize($c1,$c2) )->getProxies;
ok($p1, 'got proxy object');
ok(CORE::ref($p1) eq 'Patro::N3',  'proxy ref 1');
ok(Patro::ref($p1) eq 'CODE' ||
   Patro::ref($p1) eq 'CODE*', 'proxy ref 2');

my $x = 5;
my $z = $p1->($x);
ok($z==19, "return value ok");
ok($x==25, "side effect ok");

$x = 6;
$z = $p2->sqr($x);
ok($z==23, "return value ok");
ok($x==36, "side effect ok");

done_testing;
