use Test::More;
use Carp 'verbose';
use Patro ':test', ':insecure';
use 5.010;
use Scalar::Util 'reftype';
use Symbol;
use strict;
use warnings;

# exercise operations for proxies to dirhandles
#   -X, chdir, lstat, opendir/readdir/rewinddir/seekdir/telldir,closedir ,stat
#
#   opendir is an insecure operation
#   chdir is an insecurre operation

my $d9 = Symbol::gensym;
opendir $d9, 't';

my $p9 = getProxies( patronize($d9) );
ok($p9 && CORE::ref($p9) eq 'Patro::N5' && Patro::ref($p9) eq 'GLOB',
   'ref/reftype for proxy ok');

 SKIP: {
     if ($] < 5.012) {
	 skip("-X on proxy dirhandle requires Perl v5.12", 3);
     }
     my $z = -r $p9;
     ok($z, '-r op on proxy dirhandle ok');
     my $s = -s $p9;
     ok($s || $s eq '0', '-s op on proxy dirhandle ok');
     my $M = -M $p9;
     ok($M ne '', "-M op on proxy dirhandle ok");
}

my $f = readdir $p9;
ok($f eq '.' || $f eq '..' || $f =~ /[tm]$/,
   'read file name from proxy dirhandle');
my $t = telldir $p9;
ok($t > 0, 'telldir from proxy dirhandle nonzero after 1 read');
my @f = readdir $p9;
ok(@f > 5, 'readdir from proxy dirhandle in list context');
my $c = grep { !/t$/ } $f, @f;
ok($c == 3, '3 files found through proxy dirhandle that don\'t end in t');
my $z = seekdir $p9, $t;
my $t2 = telldir $p9;
ok($z && $t2 == $t, 'seekdir through proxy dirhandle');
$z = rewinddir $p9;
ok($z, 'rewinddir through proxy dirhandle');
ok(0 == telldir($p9), 'rewinddir makes telldir return 0');
my $f2 = readdir $p9;
ok($f eq $f2, 'readdir after rewinddir returns same file as first read');

 SKIP: {
     $z = closedir $p9;
     my $cc = Patro::client($p9);
     if ($cc->{config}{style} ne 'threaded') {
	 skip("closedir may not work on forked server?",1);
     }
     ok($z, 'closedir on proxy dirhandle');
}

local $! = 0;
$f2 = readdir $p9;
ok(!defined($f2) && $!, 'readdir on closed proxy dirhandle fails');

$z = opendir $p9, 't';

done_testing;
