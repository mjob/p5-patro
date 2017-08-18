use Test::More;
use strict;
use warnings;
use Data::Dumper;
use threads;
use threads::shared;
use Patro::CODE::Shareable;   # load after threads::shared


sub sub1 { 42 }

my $c1 = Patro::CODE::Shareable->new(\&sub1);
my $z = eval { share($c1) };
ok($z && !$@, "can share shareable code");
ok($c1->() == 42, "can invoke shareable code");

my $sub2 = sub { 19 + $_[0] };
$z = eval { share($sub2) };
ok($z && !$@, "share now works on CODE ref") or diag $@;



my %d : shared;
ok(is_shared(%d), '%d is shared');

eval { $d{foo} = $sub2 };
ok(!$d{foo} && $@, "can't add sub to shared hash");

eval { $d{bar} = Patro::CODE::Shareable->new($sub2) };
ok($d{bar} && !$@, "ok to add shareable CODE to shared hash");
ok($d{bar} && $d{bar}->(17) == 36,
   "ok to execute sub in shared hash");

my $dispatch = {
    foo => sub { $_[0]->{def}++; return 42 },
    bar => $sub2,
    baz => sub { $_[0]->{abc} += $_[1] },
    abc => 12,
    def => 34
};
ok($dispatch->{foo}->($dispatch) == 42, 'unshared dispatch code');
ok($dispatch->{baz}->($dispatch,7) == 19, 'unshared dispatch code');
ok($dispatch->{abc} == 19, 'dispatch code affected unshared obj');

my $shpatch = eval { shared_clone($dispatch) };
ok($shpatch && !$@, 'shared clone on dispatch table ok');

use Data::Dumper;
ok($shpatch->{abc} == 19 && $shpatch->{def} == 35,
   'initial shared dispatch table values ok') or diag Dumper($shpatch);

my $thr1 = threads->create( sub { $shpatch->{foo}->($shpatch) } );
my $thr2 = threads->create( sub { $shpatch->{baz}->($shpatch,-5) } );
my $j1 = $thr1->join;
my $j2 = $thr2->join;
ok($j1 == 42, 'thread 1 completed');
ok($j2 == 14, 'thread 2 completed');
ok($shpatch->{def} == 36, 'shared hash updated by shared code');
ok($shpatch->{abc} == 14, 'shared hash updated by shared code');



done_testing();