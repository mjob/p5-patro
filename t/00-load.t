#! perl
use strict;
use warnings;
use Test::More;

diag "Patro on $^O $]";
use_ok( 'Patro' );
use_ok( 'Patro::Server' );
diag "Threads avail: ", $threads::threads || 0;
done_testing();

