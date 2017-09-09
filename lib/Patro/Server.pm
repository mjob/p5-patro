package Patro::Server;
use strict;
use warnings;
use Carp;
eval "use Sys::HostAddr";
use Socket ();
use Scalar::Util 'reftype';
use POSIX ':sys_wait_h';
require overload;

our $threads_avail;
*sxdiag = sub {};
if ($ENV{PATRO_SERVER_DEBUG}) {
    *sxdiag = *::xdiag;
}

our $VERSION = '0.12';
our @SERVERS :shared;
our %OPTS = ( # XXX - needs documentation
    keep_alive => 30,
    idle_timeout => 30,
    fincheck_freq => 5,
);

sub new {
    my $pkg = shift;
    my $opts = shift;

    my $host = $ENV{HOSTNAME} // qx(hostname) // "localhost";
    if ($INC{'Sys/HostAddr.pm'}) {
	my $host2 = Sys::HostAddr->new->main_ip;
	$host = $host2 if $host2;
    }
    chomp($host);

    socket(my $socket, Socket::PF_INET(), Socket::SOCK_STREAM(),
	   getprotobyname("tcp")) || croak __PACKAGE__, " socket: $!";
    setsockopt($socket, Socket::SOL_SOCKET(), Socket::SO_REUSEADDR(),
	       pack("l",1)) || croak __PACKAGE__, " setsockopt: $!";
    my $sockaddr = Socket::pack_sockaddr_in(0, Socket::inet_aton($host));
    bind($socket, $sockaddr) || croak __PACKAGE__, " bind: $!";
    listen($socket, Socket::SOMAXCONN()) || croak __PACKAGE__, " listen: $!";
    $sockaddr = getsockname($socket);
    my ($port,$addr) = Socket::unpack_sockaddr_in($sockaddr);

    my $meta = {
	sockaddr => $sockaddr,
	socket => $socket,
	host => $host,
	host2 => Socket::inet_aton($addr),
	port => $port,

	creator_pid => $$,
	creator_tid => $threads_avail && threads->tid,
	style => $threads_avail ? 'threaded' : 'forked',

	keep_alive => $OPTS{keep_alive},
	idle_timeout => $OPTS{idle_timeout},
	version => $Patro::Server::VERSION,
    };

    $Patro::SERVER_VERSION = $Patro::Server::VERSION;

    my $obj = {};
    my @store;

    if ($threads_avail) {
	for (@_) {
	    local $threads::shared::clone_warn = undef;
	    eval { $_ = threads::shared::shared_clone($_) };
	    if ($@ =~ /CODE|GLOB/) {
		require Patro::LeumJelly;
		warn "I am really surprised to see this message";
		warn $@;
		$threads::shared::clone_warn = 0;
		$_ = threads::shared::shared_clone($_);
	    }
	}
    }
    foreach my $o (@_) {
	my ($num,$str);
	{
	    no overloading;
	    no warnings 'portable';
	    $str = "$o";
	    ($num) = $str =~ /x(\w+)/;
	    $num = hex($num);
	}
	$obj->{$num} = $o;
	my $reftype = Scalar::Util::reftype($o);
	my $ref = CORE::ref($o);
	if ($ref eq 'threadsx::shared::code') {
	    $ref = $reftype = 'CODE*';
	} elsif ($ref eq 'threadsx::shared::glob') {
	    $ref = $reftype = 'GLOB';
	}
	my $store = {
	    ref => $ref,
	    reftype => $reftype,
	    id => $num
	};
	if (overload::Overloaded($o)) {
	    if ($ref ne 'CODE' && $ref ne 'CODE*' && $ref ne 'GLOB') {
		$store->{overload} = _overloads($o);
	    }
	}
	push @store, $store;
    }
    my $self = bless {
	meta => $meta,
	store => \@store,
	obj => $obj
    }, __PACKAGE__;
    $self->{config} = $self->config;
    $self->start_server;
    eval { push @SERVERS, $self };
    if (@SERVERS == 1) {
	eval q~END {
            if ($Patro::Server::threads_avail) {
                $_->detach for threads->list(threads::running);
	    }
	}~;
    }
    return $self;
}


sub start_server {
    my $self = shift;
    my $meta = $self->{meta};
    if ($meta->{style} eq 'threaded') {
	my $server_thread;
	$server_thread = threads->create(
	    sub {
		$SIG{KILL} = sub { exit };
		$SIG{CHLD} = sub { $self->watch_for_finishers(@_) };
		$SIG{ALRM} = sub { $self->watch_for_finishers(@_) };
		if ($self->{meta}{pid_file}) {
		    open my $fh, '>>', $self->{meta}{pid_file};
		    flock $fh, 2;
		    seek $fh, 0, 2;
		    print {$fh} "$$-", threads->tid, "\n";
		    close $fh;
		}
		$self->accept_clients;
		return;
	    } );
	$self->{meta}{server_thread} = $server_thread;
	$self->{meta}{server_pid} = $$;
	$self->{meta}{server_tid} = $server_thread->tid;
	#$server_thread->detach;
    } else {
	my $pid = CORE::fork();
	if (!defined($pid)) {
	    croak __PACKAGE__, " fork: $!";
	}
	if ($pid == 0) {
	    if ($self->{meta}{pid_file}) {
		open my $fh, '>>', $self->{meta}{pid_file};
		flock $fh, 2;
		seek $fh, 0, 2;
		print {$fh} "$$\n";
		close $fh;
	    }
	    $self->accept_clients;
	    exit;
	}
	$self->{meta}{server_pid} = $pid;
    }
}

# return list of operators that are overloaded on the given object
my @oplist;
sub _overloads {
    my $obj = shift;
    return unless overload::Overloaded($obj);
    if (!@oplist) {
	@oplist = split ' ',join(' ',values %overload::ops);
    }

    my %ops = map { $_ => 1 } grep { overload::Method($obj,$_) } @oplist;

    # we also need to account for the operations that are *implicitly*
    # overloaded.

    # Many ops can be generated out of 0+, "", or bool
    if ($ops{"0+"} || $ops{'""'} || $ops{bool}) {
	$ops{$_}++ for qw(0+ "" bool int ! qr . x .= x= <> -X);
    }

    # assignment ops can be generated from binary ops
    foreach my $binop (qw(. x + - * / ** % & | ^ << >> &. |. ^.)) {
	$ops{$binop . "="}++ if $ops{$binop};
    }

    # all comparison ops can be generated from <=> and cmp
    @ops{qw{< <= > >= == !=}} = (1) x 6 if $ops{"<=>"};
    @ops{qw(le lt ge gt eq ne)} = (1) x 6 if $ops{cmp};

    $ops{neg}++ if $ops{"-"};
    $ops{"--"}++ if $ops{"-="};
    $ops{abs}++ if $ops{"<"} && $ops{neg};
    $ops{"++"}++ if $ops{"+="};

    # all ops are overloaded if there is a 'nomethod' specified
    @ops{@oplist} = (1) x @oplist if $ops{nomethod};
    return [keys %ops];
}

sub config {
    my $self = shift;
    my $config_data = {
	host => $self->{meta}{host},
	port => $self->{meta}{port},
	store => $self->{store},
	style => $self->{meta}{style},
	version => $Patro::Server::VERSION
    };
    return bless $config_data, 'Patro::Config';
}

sub Patro::Config::to_string {
    my ($self) = @_;
    return Patro::LeumJelly::serialize({%$self});
}

sub Patro::Config::to_file {
    my ($self,$file) = @_;
    if (!$file) {
	# TODO: select a temp filename
    }
    my $fh;
    if (!open($fh, '>', $file)) {
	croak "Patro::Config::to_file: could not write cfga file '$file': $!";
    }
    print {$fh} $self->to_string;
    close $fh;
    return $file;
}

sub Patro::Config::from_string {
    my ($self, $string) = @_;
    my $cfg = Patro::LeumJelly::deserialize($string);
    return bless $cfg, 'Patro::Config';
}

sub Patro::Config::from_file {
    my ($self, $file) = @_;
    if (!defined($file) && !ref($self) && $self ne 'Patro::Config') {
	$file = $self;
    }
    my $fh;
    if (ref($file) eq 'GLOB') {
	$fh = $file;
    } elsif (!open $fh, '<' ,$file) {
	croak "Patro::Config::fron_file: could not read cfg file '$file': $!";
    }
    my $data = <$fh>;
    close $fh;
    return Patro::Config->from_string($data);
}

sub accept_clients {
    # accept connection from client
    # spin off connection to separate thread or process
    # perform request_response_loop on the client connection
    my $self = shift;
    my $meta = $self->{meta};

    $meta->{last_connection} = time;
    $meta->{finished} = 0;

    while (!$meta->{finished}) {
	$SIG{CHLD} = sub { $self->watch_for_finishers(@_) };
	$SIG{ALRM} = sub { $self->watch_for_finishers(@_) };
	alarm ($OPTS{fincheck_freq} || 5);
	my $client;
	my $server = $meta->{socket};
	my $paddr = accept($client,$server);
	if (!$paddr) {
	    next if $!{EINTR};
	    next if $!{ECHILD} || $!==10;   # !?! why $!{ECHILD} not suff on Lin?
	    ::xdiag("accept failure, %errno is",\%!);
	    croak __PACKAGE__, ": accept ", 0+$!," $!";
	}
	$meta->{last_connection} = time;

	$self->start_subserver($client);
	$self->watch_for_finishers('MAIN');
    }
}

sub start_subserver {
    my ($self,$client) = @_;
    if ($self->{meta}{style} eq 'forked') {
	my $pid = CORE::fork();
	if (!defined($pid)) {
	    croak __PACKAGE__,": fork after accept $!";
	}
	if ($pid != 0) {
	    if ($self->{meta}{pid_file}) {
		open my $fh, '>>', $self->{meta}{pid_file};
		flock $fh, 2;
		seek $fh, 0, 2;
		print {$fh} "$pid\n";
		close $fh;
	    }
	    $self->{meta}{pids}{$pid}++;
	    return;
	}
	$self->request_response_loop($client);
	exit;
    } else {
	my $subthread = threads->create(
	    sub {
		$self->request_response_loop($client);
		threads->self->detach;
		return;
	    } );
	if ($self->{meta}{pid_file}) {
	    open my $fh, '>>', $self->{meta}{pid_file};
	    flock $fh, 2;
	    seek $fh, 0, 2;
	    print {$fh} "$$-", $subthread->tid, "\n";
	    close $fh;
	}
	$self->{meta}{pids}{"$$-" . $subthread->tid}++;
	push @{$self->{meta}{subthreads}}, $subthread;

	# $subthread->detach ?

	return;
    }
}

sub watch_for_finishers {
    my ($self,$sig) = @_;
    alarm 0;

    # XXX - how do you know when a thread is finished?
    # what if it is a detached thread?

    while ((my $pid = waitpid(-1,WNOHANG())) > 0 && WIFEXITED($?)) {
	delete $self->{meta}{pids}{$pid};
    }
    if ($self->{meta}{subthreads}) {
	my $n = @{$self->{meta}{subthreads}};
	my $n1 = threads->list(threads::all());
	my $n2 = threads->list(threads::running());
	my @joinable = threads->list(threads::joinable());
	if (@joinable) {
	    foreach my $subthread  (@joinable) {
		my ($i) = grep {
		    $self->{meta}{subthreads}{$_} == $subthread 
		} 0 .. $n-1;
		if (!defined($i)) {
		    warn "subthread $subthread not found on this server!";
		    next;
		}
		$self->{meta}{subthreads}[$i]->join;
		$self->{meta}{subthreads}[$i] = undef;
	    }
	    $self->{meta}{subthreads} =
		[ grep { defined } @{$self->{meta}{subthreads} } ];
	}
    }
    unless ($self->still_active) {
	$self->{meta}{finished}++;
    }
    $SIG{ALRM} = sub { $self->watch_for_finishers(@_) };
    $SIG{CHLD} = sub { $self->watch_for_finishers(@_) };
    alarm ($OPTS{fincheck_freq} || 5);
}

sub still_active {
    my $self = shift;
    my $meta = $self->{meta};
    if (time <= $meta->{keep_alive}) {
	return 1;
    }
    if (time < $meta->{last_connection} + $meta->{idle_timeout}) {
	return 1;
    }
    if (keys %{$meta->{pids}}) {
	return 1;
    }
    return;
}

sub request_response_loop {
    my ($self, $client) = @_;

    local $Patro::Server::disconnect = 0;
    my $fh0 = select $client;
    $| = 1;
    select $fh0;

    while (my $req = readline($client)) {
	next unless $req =~ /\S/;
	sxdiag("server: got request '$req'");
	my $resp = $self->process_request($req);
	sxdiag("server: response to request is ",$resp);
	$resp = $self->serialize_response($resp);
	sxdiag("server: serialized response to request is ",$resp);
	print {$client} $resp,"\n";
	last if $Patro::Server::disconnect;
    }
    close $client;
    return;
}

sub serialize_response {
    my ($self, $resp) = @_;
    if ($resp->{context}) {
	if ($resp->{context} == 1) {
	    $resp->{response} = patrol($self,$resp,$resp->{response});
	} elsif ($resp->{context} == 2) {
	    $resp->{response} = [
		map patrol($self,$resp,$_), @{$resp->{response}} ];
	}
    }
    $resp = Patro::LeumJelly::serialize($resp);
    return $resp;
}

sub process_request {
    my ($self, $request) = @_;
    croak "process_request: invalid non-scalar request" if ref($request);

    $request = Patro::LeumJelly::deserialize($request);
    my $topic = $request->{topic};
    my $command = $request->{command};
    my $has_args = $request->{has_args};
    my $args = $request->{args};
    my $ctx = $request->{context};
    my $id = $request->{id};

    if (!defined $topic) {
	Carp::confess "process_request: bad topic in request '$_[1]'";
    }
    if ($request->{has_args}) {
	$args = [ map {
	    if (ref($_) eq '.Patroon') {
		if (!defined $$_) {
		    croak "server: argument $_ in $topic request refers to ",
			"undefined reference";
		}
#		::xdiag("server: arg $$_ from client is .Patroon");
		$self->{obj}{$$_}
	    } else {
		$_
	    }  } @{$request->{args}} ];
    }

    if ($topic eq 'META') {
	if ($command eq 'disconnect') {
	    $Patro::Server::disconnect = 1;
	    return { disconnect_ok => 1 };
	} else {
	    my $obj = $self->{obj}{$id};
	    if ($command eq 'ref') {
		return $self->scalar_response(ref($obj));
	    } elsif ($command eq 'reftype') {
		return $self->scalar_response(Scalar::Util::reftype($obj));
	    } elsif ($command eq 'destroy') {
		delete $self->{obj}{$id};
		my @ids = keys %{$self->{obj}};
		if (@ids == 0) {
		    return { disconnect_ok => 1 };
		    $Patro::Server::disconnect = 1;
		} else {
		    return { disconnect_ok => 0,
			     num_remaining_objs => 0+@ids };
		}
	    } else {
		return $self->error_response(
		    "Patro: unsupported meta command '$command'");
	    }
	}
    }

    elsif ($topic eq 'HASH') {
	my $obj = $self->{obj}{$id};
	if (Scalar::Util::reftype($obj) ne 'HASH') {
	    return $self->error_response("Not a HASH reference");
	}
	my $resp = eval { $self->process_request_HASH(
			      $obj,$command,$has_args,$args) };
	return $@ ? $self->error_response($@) : $resp;
    }

    elsif ($topic eq 'ARRAY') {
	my $obj = $self->{obj}{$id};
	if (Scalar::Util::reftype($obj) ne 'ARRAY') {
	    return $self->error_response("Not an ARRAY reference");
	}
	my $resp = eval { $self->process_request_ARRAY(
			      $obj,$command,$ctx,$has_args,$args) };
	return $@ ? $self->error_response($@) : $resp;
    }

    elsif ($topic eq 'SCALAR') {
	my $obj = $self->{obj}{$id};
	if (Scalar::Util::reftype($obj) ne 'SCALAR') {
	    return $self->error_response("Not a SCALAR reference");
	}
	my $resp = eval { $self->process_request_SCALAR(
			      $obj,$command,$has_args,$args) };
	return $@ ? $self->error_response($@) : $resp;
    }
    
    elsif ($topic eq 'METHOD') {
	my @r;
	my @orig_args = $has_args ? @$args : ();
	my @orig_refs = \ (@$args);  
	my $obj = $self->{obj}{$id};
	local $! = 0;
	if ($ctx < 2) {
	    @r = scalar eval { $has_args ? $obj->$command(@$args)
				   : $obj->$command };
	} else {
	    @r = eval { $has_args ? $obj->$command(@$args)
			          : $obj->$command };
	}
	my $errno = 0 + $!;
	if ($@) {
	    return $self->error_response($@, bless{errno=>$errno},'.Patroclus');
	}
	my (@out,@outref);
	for (my $i=0; $i<@orig_refs; $i++) {
	    my $j = $i;
	    if ($orig_refs[$i] eq \$args->[$j]) {
		my $rt_orig = Scalar::Util::reftype($orig_args[$i]) // '';
		my $rt = Scalar::Util::reftype($args->[$j]) // '';
		if ('SCALAR' eq $rt_orig) {
		    if ('SCALAR' eq $rt &&
			${$orig_args[$i]} ne ${$args->[$j]}) {
			push @outref, $i, ${$args->[$j]};
		    } elsif (CORE::ref($args->[$j]) eq '') {
			push @outref, $i, $args->[$j];
		    }
		} elsif ($orig_args[$i] ne $args->[$j]) {
		    push @out, $i, $args->[$j];
		}
	    }
	}
	my @addl;
	if (@out || @outref) {
	    @addl = (bless { out => \@out, outref => \@outref }, '.Patroclus');
	    if ($errno) {
		$addl[0]{errno} = $errno;
	    }
	} elsif ($errno) {
	    @addl = (bless { errno => $errno }, '.Patroclus');
	}
	if ($ctx >= 2) {
	    return $self->list_response(@r, @addl);
	} elsif ($ctx == 1 && defined $r[0]) {
	    return $self->scalar_response($r[0], @addl);
	} else {
	    return $self->void_response(@addl);
	}
    }

    elsif ($topic eq 'CODE') {
	my $sub = $self->{obj}{$id};
	my @r;
	if (ref($sub) eq 'threadsx::shared::code') {
	    # not necessary if server uses perl >=v5.18
	    $sub = $sub->code;
	}
	my @orig_args = @$args;
	local $! = 0;
	if ($ctx < 2) {
	    @r = scalar eval { $has_args ? $sub->(@$args) : $sub->() };
	} else {
	    @r = eval { $has_args ? $sub->(@$args) : $sub->() };
	}
	my $errno = 0 + $!;
	if ($@) {
	    if ($errno) {
		$errno = bless { errno => $errno }, '.Patroclus';
		return $self->error_response($@, $errno);
	    } else {
		return $self->error_response($@);
	    }
	}
	my (@out,@outref);
	for (my $i=0; $i<@orig_args; $i++) {
	    if ('SCALAR' eq (Scalar::Util::reftype($orig_args[$i]) // '')) {
		if ('SCALAR' eq (Scalar::Util::reftype($args->[$i]) // '') &&
		    ${$orig_args[$i]} ne ${$args->[$i]}) {
		    push @outref, $i, ${$args->[$i]};
		} elsif (CORE::ref($args->[$i]) eq '') {
		    push @outref, $i, $args->[$i];
		}
	    } elsif ($orig_args[$i] ne $args->[$i]) {
		push @out, $i, $args->[$i];
	    }
	}
	my @addl;
	if (@out || @outref) {
	    @addl = (bless { out => \@out, outref => \@outref }, '.Patroclus');
	    if ($errno) {
		$addl[0]{errno} = $errno;
	    }
	} elsif ($errno) {
	    @addl = (bless { errno => $errno }, '.Patroclus');
	}
	if ($ctx >= 2) {
	    return $self->list_response(@r, @addl);
	} elsif ($ctx == 1 && defined($r[0])) {
	    return $self->scalar_response($r[0], @addl);
	} else {
	    return $self->void_response(@addl);
	}
    }

    elsif ($topic eq 'OVERLOAD') {
	my $obj = $self->{obj}{$id};
	return $self->process_request_OVERLOAD($obj,$command,$args,$ctx);
    }

    elsif ($topic eq 'HANDLE') {
	my $obj = $self->{obj}{$id};
	return $self->process_request_HANDLE(
	    $obj,$command,$ctx,$has_args,$args);
    }

    else {
	return $self->error_response(
	    __PACKAGE__,": unrecognized topic '$topic'");
    }
}

sub process_request_OVERLOAD {
    my ($self,$x,$op,$args,$context) = @_;
    my ($y,$swap) = @$args;
    if ($swap) {
	($x,$y) = ($y,$x);
    }
    local $@ = '';
    my $z;
    if ($op =~ /[&|~^][.]=?/) {
        $op =~ s/\.//;
    }
    if ($op eq '-X') {
        $z = eval "-$y \$x";
    } elsif ($op eq 'neg') {
        $z = eval { -$x };
    } elsif ($op eq '!' || $op eq '~' || $op eq '++' || $op eq '--') {
        $z = eval "$op\$x";
    } elsif ($op eq 'qr') {
        $z = eval { qr/$x/ };
    } elsif ($op eq 'atan2') {
        $z = eval { atan2($x,$y) };
    } elsif ($op eq 'cos' || $op eq 'sin' || $op eq 'exp' || $op eq 'abs' ||
             $op eq 'int' || $op eq 'sqrt' || $op eq 'log') {
        $z = eval "$op(\$x)";
    } elsif ($op eq 'bool') {
        $z = eval { $x ? 1 : 0 };  # this isn't right
    } elsif ($op eq '0+') {
        $z = eval "0 + \$x"; # this isn't right, either
    } elsif ($op eq '""') {
        $z = eval { "$x" };
    } elsif ($op eq '<>') {
        # always scalar context readline
        $z = eval { readline($x) };
    } else {  # binary operator
        $z = eval "\$x $op \$y";
    }
    if ($@) {
	return $self->error_response($@);
    }
    if ($threads_avail) {
	$z = threads::shared::shared_clone($z);
    }
    return $self->scalar_response($z);
}

sub process_request_HASH {
    my ($self,$obj,$command,$has_args,$args) = @_;
    if ($command eq 'STORE') {
	my ($key,$val) = @$args;
	my $old_val = $obj->{$key};
	$obj->{$key} = $val;
	return $self->scalar_response($old_val);
    } elsif ($command eq 'FETCH') {
	my $key = $args->[0];
	my $val = $obj->{$key};
	return $self->scalar_response( $obj->{$args->[0]} );
    } elsif ($command eq 'DELETE') {
	return $self->scalar_response( delete $obj->{$args->[0]} );
    } elsif ($command eq 'EXISTS') {
	return $self->scalar_response( exists $obj->{$args->[0]} );
    } elsif ($command eq 'CLEAR') {
	%$obj = ();
	return $self->void_response;
    } elsif ($command eq 'FIRSTKEY') {
	keys %$obj;
	my ($k,$v) = each %$obj;
	return $self->scalar_response($k);
    } elsif ($command eq 'NEXTKEY') {
	my ($k,$v) = each %$obj;
	return $self->scalar_response($k);
    } elsif ($command eq 'SCALAR') {
	my $n = scalar %$obj;
	return $self->scalar_response($n);
    }
    die "tied HASH function '$command' not recognized";
}

sub process_request_ARRAY {
    my ($self,$obj,$command,$context,$has_args,$args) = @_;
    if ($command eq 'STORE') {
	my ($index,$val) = @$args;
	return $self->scalar_response( $obj->[$index] = $val );
    } elsif ($command eq 'FETCH') {
	return $self->scalar_response( $obj->[$args->[0]] );
    } elsif ($command eq 'FETCHSIZE') {
	return $self->scalar_response( scalar @$obj );
    } elsif ($command eq 'STORESIZE') {
	my $n = $#{$obj} = $args->[0];
	return $self->scalar_response($n+1);
    } elsif ($command eq 'SPLICE') {
	my ($off,$len,@list) = @$args;
	if ($off < 0) {
	    $off += @$obj;
	    if ($off < 0) {
		croak "Modification of non-createable array value attempted, ",
		    "subscript $off";
	    }
	}

	if ($len eq 'undef') {
	    $len = @{$obj} - $off;
	}
	if ($len < 0) {
	    $len += @{$obj} - $off;
	    if ($len < 0) {
		$len = 0;
	    }
	}

	my @val;
	if ($threads_avail && threads::shared::is_shared($obj)) {
	    # "Splice not implemented for shared arrays" in threads::shared.
	    # This is a workaround
	    @val = @{$obj}[$off .. $off+$len-1];
	    my @tmp = @{$obj}[0..$off-1];
	    push @tmp, @list;
	    push @tmp, @{$obj}[$off+$len..$#{$obj}];
	    @$obj = @tmp;
	} else {
	    @val = splice @{$obj},$off,$len,@list;
	}

	# this is the only ARRAY function that doesn't assume scalar context
	if ($context == 1) {
	    return $self->scalar_response(@val > 0 ? $val[-1] : undef);
	}	
	return $self->list_response(@val);
    } elsif ($command eq 'PUSH') {
	my $n = push @{$obj}, map threads::shared::shared_clone($_),@$args;
	return $self->scalar_response($n);
    } elsif ($command eq 'UNSHIFT') {
	my $n = unshift @$obj, map threads::shared::shared_clone($_),@$args;
	return $self->scalar_response($n);
    } elsif ($command eq 'POP') {
	return $self->scalar_response(pop @$obj);
    } elsif ($command eq 'SHIFT') {
	return $self->scalar_response(shift @$obj);
    } elsif ($command eq 'EXISTS') {
	return $self->scalar_response(exists $obj->[$args->[0]]);
    }

    die "tied ARRAY function '$command' not recognized";
}

sub process_request_SCALAR {
    my ($self,$obj,$command,$has_args,$args) = @_;
    if ($command eq 'STORE') {
	${$obj} = threads::shared::shared_clone($args->[0]);
	return $self->scalar_response(${$obj});
    } elsif ($command eq 'FETCH') {
	my $return = $self->scalar_response(${$obj});
	return $return;
    }
    die "topic 'SCALAR': command '$command' not recognized";
}

sub process_request_HANDLE {
    my ($self,$obj,$command,$context,$has_args,$args) = @_;
    my $fh = ref($obj) eq 'threadsx::shared::glob' ? $obj->glob : $obj;
    if ($command eq 'PRINT') {
	my $z = print {$fh} @$args;
	return $self->scalar_response($z);
    } elsif ($command eq 'PRINTF') {
	if ($has_args) {
	    my $template = shift @$args;
	    my $z = printf {$fh} $template, @$args;
	    return $self->scalar_response($z);
	} else {
	    # I don't think we can get here through the proxy
	    my $z = printf {$fh} "";
	    return $self->scalar_response($z);
	}
    } elsif ($command eq 'WRITE') {
	if (@$args < 2) {
	    return $self->error_response("Not enough arguments for syswrite");
	}
	return $self->scalar_response(syswrite $fh, $args->[0],
				      $args->[1] // undef, $args->[2] // undef);
    } elsif ($command eq 'READLINE') {
	local $! = 0;
	my @val;
	if ($context > 1) {
	    my @val = readline($fh);
	    if ($!) {
		push @val, bless { errno => 0+$! }, '.Patroclus';
	    }
	    return $self->list_response(@val);
	} else {
	    my $val = readline($fh);
	    if ($!) {
		return $self->scalar_response($val, {errno => 0+$!});
	    } else {
		return $self->scalar_response($val);
	    }
	}
    } elsif ($command eq 'GETC') {
	local $! = 0;
	my $ch = getc($fh);
	return $self->scalar_response($ch);
    } elsif ($command eq 'READ' || $command eq 'READ?' ||
	     $command eq 'SYSREAD') {
	local $Patro::read_sysread_flag;  # don't clobber
	if (@$args < 2) {
	    # I don't think we can get here through the proxy
	    return $self->error_response("Not enough arguments for read");
	}
	my ($buffer, $len, $off) = @$args;
	my $z;
	if ($command eq 'SYSREAD' || ($command eq 'READ?' && fileno($fh) >= 0)) {
	    $z = sysread $fh, $buffer, $len, $off || 0;
	} else {
	    # sysread doesn't work, for example, on file handles opened
	    # from a reference to a scalar
	    $z = read $fh, $buffer, $len, $off || 0;
	}
	if ($@) {
	    return $self->error_response($@);
	} else {
	    return $self->scalar_response($z, { out => [0,$buffer] })
	}
    } elsif ($command eq 'EOF') {
	return $self->scalar_response( eof($fh) );
    } elsif ($command eq 'FILENO') {
	my $z = fileno($fh);
	return $self->scalar_response($z);
    } elsif ($command eq 'SEEK') {
	if (@$args < 2) {
	    return $self->error_response("Not enough arguments for seek");
	} elsif (@$args > 2) {
	    return $self->error_response("Too many arguments for seek");
	} else {
	    my $z = seek $fh, $args->[0], $args->[1];
	    return $self->scalar_response($z);
	}
    } elsif ($command eq 'TELL') {
	my $z = tell($fh);
	return $self->scalar_response($z);
    } elsif ($command eq 'BINMODE') {
	local $! = 0;
	my $z;
	if (@$args) {
	    $z = binmode $fh, $args->[0];
	} else {
	    $z = binmode $fh;
	}
	if (!$z) {
	    return $self->scalar_response($z, { errno => 0+$! });
	} else {
	    return $self->scalar_response($z);
	}
    } elsif ($command eq 'CLOSE') {
	if ($Patro::SECURE) {
	    return $self->error_response(
		"Patro: insecure CLOSE operation on proxy filehandle");
	}
	local $! = 0;
	local $? = 0;
	my $z = close $fh;
	my $val = bless{ errno => 0 + $! }, '.Patroclus';
	if ($?) { 
	    $val->{child_error} = $?;
	}
	if ($val->{errno} || $val->{child_error}) {
	    return $self->scalar_response($z, $val);
	} else {
	    return $self->scalar_response($z);
	}
    } elsif ($command eq 'OPEN') {
	if ($Patro::SECURE) {
	    return $self->error_response(
		"Patro: insecure OPEN operation on proxy filehandle");
	}
	local $! = 0;
	my $z;
	my $mode = shift @$args;
	if (@$args == 0) {
	    $z = open $fh, $mode;
	} else {
	    my $expr = shift @$args;
	    if (@$args == 0) {
		$z = open $fh, $mode, $expr;
	    } else {
		$z = open $fh, $mode, $expr, @$args;
	    }
	}

	# it is hard to set autoflush from the proxy.
	# Since it is usually what you want, let's do it here.
	if ($z) {
	    my $fh_sel = select $fh;
	    $| = 1;
	    select $fh_sel;
	}
	
	if ($!) {
	    return $self->scalar_response($z, {errno => 0+$!});
	} else {
	    return $self->scalar_response($z);
	}
    }
    return $self->error_response("tied HANDLE function '$command' not found");
}
    
# we should not send any serialized references back to the client.
# replace any references in the response with an
# object id.
sub patrol {
    my ($self,$resp,$obj) = @_;
    sxdiag("patrol: called on: ",defined($obj) ? "$obj" : "<undef>");
    return $obj unless ref($obj);

    if ($threads_avail) {
	if (ref($obj) eq 'CODE') {
	    $obj = threadsx::shared::code->new($obj);
	    sxdiag("patrol: coderef converted");
	} elsif (ref($obj) eq 'GLOB') {
	    $obj = threadsx::shared::glob->new($obj);
	    sxdiag("patrol: glob converted");
	}
    }

    my $id = do {
	no overloading;
	0 + $obj;
    };

    if (!$self->{obj}{$id}) {
	$self->{obj}{$id} = $obj;
	my $ref = ref($obj);
	my $reftype;
	if ($ref eq 'threadsx::shared::code') {
	    $ref = 'CODE';
	    $reftype = 'CODE';
	} elsif ($ref eq 'threadsx::shared::glob') {
	    $ref = 'GLOB';
	    $reftype = 'GLOB';
	} else {
	    $reftype = reftype($obj);
	}
	sxdiag("patrol: ref types for $id are $ref,$reftype");
	$resp->{meta}{$id} = {
	    id => $id, ref => $ref, reftype => $reftype
	};
	if (overload::Overloaded($obj)) {
	    $resp->{meta}{$id}{overload} = _overloads($obj);
	}
	sxdiag("new response meta: ",$resp->{meta}{$id});
    } else {
	sxdiag("id $id has been seen before");
    }
    return \$id;
}

sub void_response {
    my $addl = {};
    if (@_ > 0 && CORE::ref($_[-1]) eq '.Patroclus') {
	$addl = pop @_;
    }
    return +{ context => 0, response => undef, %$addl };
}

sub scalar_response {
    my ($self,$val,$addl) = @_;
    return +{
	context => 1,
	response => $val,
	$addl ? %$addl : ()
    };
}

sub list_response {
    my ($self,@val) = @_;
    my $addl = {};
    if (@val && CORE::ref($val[-1]) eq '.Patroclus') {
	$addl = pop @val;
    }
    return +{
	context => 2,
	response => \@val,
	%$addl
    };
}

sub error_response {
    my ($self,@msg) = @_;
    if (@msg && CORE::ref($msg[-1]) eq '.Patroclus') {
	my $val = pop @msg;
	return { error => join('',@msg), %$val };
    }
    return { error => join('',@msg) };
}

sub TEST_MODE {
    if ($INC{'perl5db.pl'}) {
	::xdiag("TEST_MODE adjusted for debugging");
	$OPTS{keep_alive} = 3600;
	$OPTS{fincheck_freq} = 3500;
	$OPTS{idle_timeout} = 3600;
	alarm 9999;
	return;
    }
    $OPTS{keep_alive} = 2;
    $OPTS{fincheck_freq} = 2;
    $OPTS{idle_timeout} = 1;
    if ($threads_avail) {
	$OPTS{fincheck_freq} = "0 but true";	    
    }
}

1;

=head1 NAME

Patro::Server - remote object server for Patro

=head1 VERSION

0.12

=head1 DESCRIPTION

A server class for making references available to proxy clients
in the L<Patro> distribution.
The server handles requests for any references that are being served,
manipulates references on the server, and returns the results of
operations to the proxy objects on the clients.

=head1 LICENSE AND COPYRIGHT

MIT License

Copyright (c) 2017, Marty O'Brien

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
