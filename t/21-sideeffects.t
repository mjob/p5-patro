use Test::More;
use Patro ':test';
use Scalar::Util 'reftype';
use 5.010;

sub foo::sqr { $_[1] *= $_[1] ; 23 };

sub sqr { $_[0] *= $_[0]; 19 }

sub foo::enoent { open my $zh, "<", "/a/bogus:file/that/doesn't/exist"; 11 }

sub foo::manip { my $self=shift;my $c = pop; $_[1] *= 4; 13 }
sub foo::manip2 { my $self=shift;shift @_ for 1..5; $_[1] = 47; 7 }
sub foo::manip3 { 
		  my $self=shift; 
		  $_[0]->[$_[1]][$_[2]]++;
		  4
}
sub foo::manip4 { my $self=shift; $_[0]->[$_[1]] = $_[2] ; 'huzzah' }

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

local $! = 0;
ok($! == 0, 'errno test init');
ok(11 == $p2->enoent(), 'proxy method call');
ok($!, '... that sets $!');

# what if the code slurps arguments?
my ($r,$s,$t) = (10,20,30);
ok(13 == $p2->manip($r,$s,$t), 'proxy method call');
ok($r == 10 && $t == 30, '... that leaves manipulated args alone');
ok($s == 80, '... but can still manipulate other args');

my @a4 = (1..20);
$z = eval { $p2->manip2(@a4) };
ok($z == 7, 'proxy method call');
ok($a4[6] == 47, '... that manipulates args');
ok($a4[19] == 20, '... and leaves other args alone');

my $a5 = [[1,2,3],[4,5,6],[7,8,9]];
$z = eval { $p2->manip3($a5, 2, 1) };
ok($z == 4, 'proxy method call') or ::xdiag([$z,$@]);
ok($a5->[2][1] == 9, '... that manipulates nested data')
    or ::xdiag($a5);

my $a6 = [1,2,3,4,5];
$z = eval { $p2->manip4($a6, 3, 17) };
ok($z eq 'huzzah', 'proxy method call');
ok($a6->[3] == 17, '... that manipulates nested data');

done_testing;
