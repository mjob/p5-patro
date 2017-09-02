use Test::More;
use Carp 'verbose';
use Patro ':test';
use 5.010;
use Scalar::Util 'reftype';
use Symbol;

my $r0 = '';
my $fh; # = Symbol::gensym();
my $z = open $fh, '>', 't/t-05.out';
ok(-f 't/t-05.out', 'test file created');
ok($z, 'remote filehandle opened successfully');
$z = open my $th, '<', 't/t-05.out';
ok($z, 'test filehandle opened successfully');

my $fh_sel = select $fh;
$| = 1;
select $fh_sel;


ok($fh && ref($fh) eq 'GLOB', 'created remote filehandle');
my $cfg = patronize($fh);
ok($cfg, 'got config for patronize glob');
my $cfgstr = $cfg->to_string;
ok($cfgstr, 'got string representation of Patro config');

my ($ph) = Patro->new($cfgstr)->getProxies;
ok($ph, 'client as boolean, loaded from config string');
is(CORE::ref($ph), 'Patro::N1', 'client ref');
is(Patro::ref($ph), 'GLOB', 'remote ref');
is(Patro::reftype($ph), 'GLOB', 'remote reftype');

my $c = Patro::client($ph);
ok($c, 'got client for remote obj');
my $THREADED = $c->{config}{style} eq 'threaded';

$z = print $ph "Hello world\n";
ok($z, 'print on remote filehandle ok');
my $line = <$th>;
ok($line eq "Hello world\n", 'output received') or diag $th;

done_testing;

END {
    unlink 't/t-05.out' unless $ENV{KEEP};
}
