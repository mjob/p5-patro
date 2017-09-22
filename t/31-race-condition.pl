use strict;
use warnings;
use Test::More;
use Patro;
use Carp;

if (!$Patro::Server::threads_avail) {
    ok(1,'synchronization tests require threads');
    done_testing;
    exit;
}

$Patro::Server::OPTS{keep_alive} = 999;
$Patro::Server::OPTS{idle_timeout} = 999;
$Patro::Server::OPTS{fincheck_freq} = 999;

my $r = { foo => 0, bar => 0 };
my $c = patronize($r);

my $N = 500;

my $t1 = threads->create(
    sub {
	my $p1 = getProxies($c);
	my ($f1,$b1) = 0;
	srand($$);
	my $t = time;
	for (my $i=0; $i<$N; $i++) {
	    my $y = rand;
	    if ($y >= 0.75) {
		$b1++;
		Patro::synchronize($p1, sub { $p1->{bar}++ });
	    } elsif ($y >= 0.5) {
		$b1--;
		Patro::synchronize($p1, sub { $p1->{bar}-- });
	    } elsif ($y >= 0.25) {
		$f1++;
		Patro::synchronize($p1, sub { $p1->{foo}++ });
	    } else {
		$f1--;
		Patro::synchronize($p1, sub { $p1->{foo}-- });
	    }
	    if ($i > 0 && $i % 100 == 0) {
		print STDERR "\$t1: ",time-$t,"s to do $i ops\n";
	    }
	}
	return [$f1,$b1];
    });

my $t2 = threads->create(
    sub {
	my ($f2,$b2) = (0,0);
	my $p2 = getProxies($c);
	for (my $i=0; $i < $N; $i++) {
	    my $y = rand;
	    if ($y >= 0.75) {
		$b2++; 
		Patro::synchronize($p2, sub { $p2->{bar}++ });
	    } elsif ($y >= 0.50) {
		$b2--; 
		Patro::synchronize($p2, sub { $p2->{bar}-- });
	    } elsif ($y >= 0.25) {
		$f2++; 
		Patro::synchronize($p2, sub { $p2->{foo}++ });
	    } else {
		$f2--; 
		Patro::synchronize($p2, sub { $p2->{foo}-- });
	    }
	}
	return [$f2,$b2];
    });

my $fb1 = $t1->join;
my $fb2 = $t2->join;

my $p3 = getProxies($c);
diag $p3->{foo}," ",$p3->{bar};
diag "dbar = ",$fb1->[0]+$fb2->[0];
diag "dfoo = ",$fb1->[1]+$fb2->[1];


