use Test::More;
#use Patro::Archy ':all', ':errno';
use strict;
use warnings;
use Time::HiRes qw(time sleep);

alarm 20;
$SIG{ALRM} = sub {
    die "$0 test took too long. It's possible there was a deadlock";
};

if (!eval "use Patro::Archy ':all',':errno'; 1") {
    diag "# synchronization tests require threads and Patro::Archy";
    ok(1,"# synchronization tests require threads and Patro::Archy");
    done_testing;
    exit;
}

my $foo = {};
my $bar = [];

close STDERR;
open STDERR, '+>', \$STDERR;
(*STDERR)->autoflush(1);

ok(plock($foo, "monitor-0"), 'lock');
ok(punlock($foo, "monitor-0"), 'unlock');
my $s0 = $STDERR;
ok(!punlock($foo, "monitor-3"), 'unlock without possession fails');
ok($! == &FAIL_INVALID_WO_LOCK, 'errno set');
ok($s0 eq '' && $STDERR =~ /unlock called on .* without lock/,
   'warning written') or diag $STDERR;
ok(plock($foo, "monitor-1"), 'lock');
my $t = time;
ok(!plock($foo,"monitor-2",-1), 'non-blocking lock failed');
ok(time - $t < 0.5, 'non-blocking lock returned quickly');

$t = time;
my $s1 = $STDERR;
ok(!plock($foo,"monitor-2",2.5), 'timed lock failed');
my $s2 = $STDERR;
is(0+$!, &FAIL_EXPIRED, '... errno set');
ok($s1 eq $s2, '... without warning');
ok(time - $t > 1.5, 'timed lock took time');
ok(punlock($foo,"monitor-1"), 'released resource');
ok(plock($foo,"monitor-2",-1), 'lock immediately accessible by new monitor');
ok(punlock($foo,"monitor-2"), 'release reference from new monitor');

# stacked lock calls

ok(plock($bar, "monitor-4"), 'got lock');
ok(plock($bar, "monitor-4"), 'stacked lock');
ok(punlock($bar, "monitor-4"), '1st unlock');
$s1 = $STDERR;
ok(!plock($bar, "monitor-5", -1), 'lock not available for new monitor');
is(0+$!, &FAIL_EXPIRED, 'errno set');
ok($s1 eq $STDERR, '... without additional warning');
ok(punlock($bar, "monitor-4"), '2nd unlock');
ok(plock($bar, "monitor-5", -1), 'lock available after 2nd unlock');
ok(punlock($bar, "monitor-5"), 'lock released from new monitor');


sub tdiag { return; print STDERR "# STEP ",@_,"\n" }

# simple wait/notify example

if (CORE::fork() == 0) {
    my $z = plock($bar, "child-4"); tdiag("1 - $z");
    sleep 3;
    $z = pwait($bar, "child-4"); tdiag("4 - $z");
    punlock($bar, "child-4"); tdiag(5);
    sleep 2;
    plock($bar, "child-6"); tdiag(6);
    pnotify($bar, "child-6"); tdiag(7);
    punlock($bar, "child-6"); tdiag(8);
    exit;
}
sleep 1;
my $v;
$! = 0;
ok(!pwait($bar, "parent-5"),"wait fails without lock");
ok($! == &FAIL_INVALID_WO_LOCK, 'errno set');
$! = 0;
ok(!pnotify($bar, "parent-5"),"notify fails without lock");
ok($! == &FAIL_INVALID_WO_LOCK, 'errno set');

$t = time;

ok($v = plock($bar, "parent-5"), 'eventually got lock'); tdiag("2 - $v");
ok(time - $t > 1.5, '... but it took a while');

ok($v = pnotify($bar,"parent-5"), 'notify ok'); tdiag("3 - $v");
$t = time;
ok(pwait($bar,"parent-5"), 'wait ok'); tdiag(9);
ok(time - $t > 1.5, '... and wait we did');
ok(punlock($bar,"parent-5"), 'unlock ok'); tdiag(10);

done_testing();
