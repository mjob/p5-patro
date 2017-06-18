package Patro::Server;
use strict;
use warnings;
use Carp;
eval "use Sys::HostAddr";
use Socket ();
use POSIX ':sys_wait_h';
require overload;

our $threads_avail = eval "use threads; use threads::shared; 1";
if (defined $ENV{PATRO_THREADS}) {
    $threads_avail = $ENV{PATRO_THREADS};
}

our $VERSION = '0.10';
our @SERVERS :shared;
our %OPTS = { # XXX - needs documentation
    keep_alive => 30,
    idle_timeout => 30,
    fincheck_freq => 5,
};

sub new {
    my $pkg = shift;
    my $opts = shift;

    my $host = $ENV{HOSTNAME} // qx(hostname) // "localhost";
    if (eval "require Sys::HostAddr;1") {
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
	idle_timeout => $OPTS{idle_timeout}
    };

    my $obj = {};
    my @store;

    if ($threads_avail) {
	$_ = shared_clone($_) for @_;
    }
    foreach my $o (@_) {
	my ($num,$str);
	{
	    no overloading;
	    $str = "$o";
	    $num = hex($str =~ /x(\w+)/);
	}
	$obj->{$num} = $o;
	my $reftype = Scalar::Util::reftype($o);
	my $ref = ref($o);
	my $store = {
	    ref => CORE::ref($o),
	    reftype => Scalar::Util::reftype($o),
	    id => $num
	};
	if (overload::Overloaded($o)) {
	    $store->{overload} = _overloads($o);
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
    push @SERVERS, $self;
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
		    print $fh "$$-", threads->tid, "\n";
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
		print $fh "$$\n";
		close $fh;
	    }
	    $self->accept_clients;
	    exit;
	}
	$self->{meta}{server_pid} = $pid;
    }
}

# return list of operators that are overloaded on the given object
sub _overloads {
    my $obj = shift;
    if (!overload::Overloaded($obj)) {
	return;
    }
    
    my @overloads;
    foreach my $opses (values %overload::ops) {
	push @overloads,
	    grep overload::Method($obj,$_), split ' ', $opses;
    }
    return \@overloads;
}

sub config {
    my $self = shift;
    my $config_data = {
	host => $self->{meta}{host},
	port => $self->{meta}{port},
	store => $self->{store}
    };
    return $config_data;
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
	    if ($!{EINTR} || $!{ECHILD}) {
		next;
	    }
	    croak __PACKAGE__, ": accept $!";
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
		print $fh "$pid\n";
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
	    print $fh "$$-", $subthread->tid, "\n";
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
#	::xdiag("thread status $n/$n1/$n2/" . scalar(@joinable));
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

    while (my $req = <$client>) {
	next unless $req =~ /\S/;
	my $resp = $self->process_request($req);
	$resp = $self->serialize_response($resp);
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
	} else {
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

    if ($topic eq 'META') {
	if ($command eq 'disconnect') {
	    $Patro::Server::disconnect = 1;
	    return { disconnect_ok => 1 };
	} else {
	    my $obj = $self->{obj}{$id};
	    if ($command eq 'ref') {
		return scalar_response(ref($obj));
	    } elsif ($command eq 'reftype') {
		return scalar_response(Scalar::Util::reftype($obj));
	    } else {
		return error_response(
		    "Patro: unsupported meta command '$command'");
	    }
	}
    }

    elsif ($topic eq 'HASH') {
	my $obj = $self->{obj}{$id};
	if (Scalar::Util::reftype($obj) ne 'HASH') {
	    return error_response("Not a HASH reference");
	}
	my $resp = eval { $self->process_request_HASH(
			      $obj,$command,$has_args,$args) };
	return $@ ? error_response($@) : $resp;
    }

    elsif ($topic eq 'ARRAY') {
	my $obj = $self->{obj}{$id};
	if (Scalar::Util::reftype($obj) ne 'ARRAY') {
	    return error_response("Not an ARRAY reference");
	}
	my $resp = eval { $self->process_request_ARRAY(
			      $obj,$command,$has_args,$args) };
	return $@ ? error_response($@) : $resp;
    }

    elsif ($topic eq 'SCALAR') {
	my $obj = $self->{obj}{$id};
	if (Scalar::Util::reftype($obj) ne 'SCALAR') {
	    return error_response("Not a SCALAR reference");
	}
	my $resp = eval { $self->process_request_SCALAR(
			      $obj,$command,$has_args,$args) };
	return $@ ? error_response($@) : $resp;
    }

    elsif ($topic eq 'METHOD') {
	return error_response("topic:'METHOD' not supported yet");
    }

    elsif ($topic eq 'OVERLOAD') {
	return error_response("topic:'OVERLOAD' not supported yet");
    }

    else {
	return error_reponse(__PACKAGE__,": unrecognized topic '$topic'");
    }
}

sub process_request_HASH {
    die "topic 'HASH' not supported yet";
}

sub process_request_ARRAY {
    die "topic 'ARRAY' not supported yet";
}

sub process_request_SCALAR {
    my ($self,$obj,$command,$has_args,$args) = @_;
    if ($command eq 'STORE') {
	${$obj} = $args->[0];
	return scalar_response(${$obj});
    } elsif ($command eq 'FETCH') {
	my $return = scalar_response(${$obj});
	return $return;
    }
    die "topic 'SCALAR': command '$command' not recognized";
}

sub scalar_response {
    my ($val) = @_;
    return +{
	context => 1,
	response => $val
    };
}

sub error_response {
    my (@msg) = @_;
    return { error => join('',@msg) };
}

sub TEST_MODE {
    $OPTS{keep_alive} = 2;
    $OPTS{fincheck_freq} = 2;
    $OPTS{idle_timeout} = 1;
    if ($threads_avail) {
	$OPTS{fincheck_freq} = "0 but true";	    
    }
}

1;
