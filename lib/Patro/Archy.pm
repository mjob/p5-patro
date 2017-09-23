# patronite is a vanadium sulfide mineral, but it could also be
# the brand name of a heavy-duty padlock, so it is a fitting
# name for the class to manage synchronization of proxy objects

package Patro::Archy;
use Fcntl qw(:flock :seek);
use File::Temp;
use Scalar::Util 'refaddr';
use Time::HiRes qw(time sleep);
use Carp;
use base 'Exporter';
our @EXPORT_OK = (qw(plock punlock pwait pnotify
		  FAIL_EXPIRED FAIL_INVALID_WO_LOCK FAIL_DEEP_RECURSION));
our %EXPORT_TAGS = (
    'all' => [qw(plock punlock pwait pnotify)],
    'errno' => [qw(FAIL_EXPIRED FAIL_INVALID_WO_LOCK FAIL_DEEP_RECURSION)]
    );

use constant {
    STATE_NULL => 0,
    STATE_WAIT => 1,
    STATE_NOTIFY => 2,
    STATE_STOLEN => 3,
    STATE_LOCK => 4,
    STATE_LOCK_MAX => 254,

    FAIL_EXPIRED => 1001,
    FAIL_INVALID_WO_LOCK => 1002,
    FAIL_DEEP_RECURSION => 1111,
};
our $VERSION = '0.16';
our $DEBUG;

my $DIR;
$DIR //= do {
    my $d = "/dev/shm/resources-$$";
    my $pid = $$;
    $d;
};
mkdir $DIR,0755 unless -d $DIR;
die "Patro::Archy requires a system with /dev/shm" unless -d $DIR;

my %lookup;

sub _unlocked { $_[0] !~ qr/[^\000-\002]/ }

sub _lookup {
    my ($id) = @_;
    $id =~ s/^\s+//;
    $id =~ s/\s+$//;
    croak "invalid monitor id '$id': id is too long" if length($id) > 20;
    open my $lock, '>>', "$DIR/.lock";
    flock $lock, LOCK_EX;
    $lookup{$id} //= do {
        my $lu;
        my $maxlu = -1;
        if (open my $fh, '<', "$DIR/.index") {
            my $data;
            while (read $fh, $data, 24) {
                my $i = substr($data,0,20);
		$i =~ s/^\s+//;
                my $val = 0 + substr($data,20,4);
                if ($val > $maxlu) {
                    $maxlu = $val;
                }
		if ($i eq $id) {
                    $lu = $val;
                    close $fh;
                    last;
                }
            }
        }
        if (!defined $lu) {
            $lu = $maxlu + 1;
            open my $fh, '>>', "$DIR/.index";
            printf $fh "%-20s%04d", $id, $lu;
            close $fh;
        }
        $lu;
    };
    close $lock;
    return $lookup{$id};
}


sub _addr {
    use B;
    my $obj = shift;
    my $addr = B::svref_2object($obj)->MAGIC;
    $addr ? $addr->OBJ->RV->IV : refaddr($obj);
}

sub plock {
    my ($obj, $id, $timeout) = @_;
    my $lu = _lookup($id);
    my $addr = _addr($obj);

    my $expire = $timeout && $timeout > 0 ? time + $timeout : 9E19;
    my $fh;
    open($fh,'+<',"$DIR/$addr") || open($fh,'+>', "$DIR/$addr") || die;
    flock $fh, LOCK_EX;

    if ($DEBUG) { print STDERR "Archy: checking state for $DIR/$addr\@$lu\n" }

    # if we already have the lock, increment the lock counter and return OK
    my $ch = _readbyte($fh,$lu);
    if ($ch >= STATE_LOCK) {
        if ($ch > STATE_LOCK_MAX) {
	    carp "Patro::Archy: deep recursion on plock for $obj";
	    $! = FAIL_DEEP_RECURSION;
	    return;
        }
	if ($DEBUG) { print STDERR "Archy: already locked \@ $lu\n" }
        _writebyte($fh,$lu,$ch+1);
        close $fh;
        return 1;
    }

    # if no one else has the lock, get the lock
    if (_unlocked(_readall($fh))) {
        _writebyte($fh, $lu, STATE_LOCK);
        close $fh;
	$DEBUG && print STDERR "Archy: acquired the lock \@ $lu\n";
        return 1;
    }
    close $fh;
    
    # if non-blocking, return EXPIRED
    if ($timeout && $timeout < 0) {
        close $fh;
	$! = FAIL_EXPIRED;
	$DEBUG && print STDERR "Archy: non-blocking, lock not avail \@ $lu\n";
	return;
    }

    # wait until timeout for the lock
    my $left = $expire - time;
    while ($left > 0) {
	$threads::threads ? threads->yield : sleep 1;

        open $fh, '+<', "$DIR/$addr";
        flock $fh, LOCK_EX;
        $left = $expire - time;
	$DEBUG && print STDERR "Archy: waiting for lock \@ $lu (up to $left)\n";

        if (_unlocked(_readall($fh))) {
            _writebyte($fh,$lu,STATE_LOCK);
	    $DEBUG && print STDERR "Archy: acquired lock \@ $lu after wait\n";
            return 1;
        }
        close $fh;
    }
    close $fh;
    $! = FAIL_EXPIRED;
    $DEBUG && print STDERR "Archy: expired waiting for lock \@ $lu\n";
    return;
}

sub punlock {
    my ($obj, $id, $count) = @_;
    my $lu = _lookup($id);
    my $addr = _addr($obj);
    $count ||= 1;

    my $fh;
    open($fh,'+<',"$DIR/$addr") || open($fh,'+>', "$DIR/$addr") || die;
    flock $fh, LOCK_EX;

    # if we already have the lock, decrement the lock counter and return OK
    $DEBUG && print STDERR "Archy: checking state for unlock \@ $lu\n";
    $ch = _readbyte($fh,$lu);
    if ($ch > STATE_LOCK) {
	if ($count < 0) {
	    $count = $ch - STATE_LOCK + 1;
	    $ch = 0;
	} else {
	    if ($count > $ch - STATE_LOCK + 1) {
		carp "punlock: count ($count) exceeded lock count (",
		    $ch - STATE_LOCK + 1, ")";
		$count = $ch - STATE_LOCK + 1;
		$ch = STATE_NULL;
	    } else {
		$ch -= $count;
	    }
	}
	if ($ch < STATE_LOCK) {
	    $ch = STATE_NULL;
	}
        _writebyte($fh,$lu,$ch);
        close $fh;
	$DEBUG && print STDERR
	    "Archy: unlock successful \@ $lu. New state $ch\n";
        return $count;
    } elsif ($ch == STATE_LOCK) {
	if ($count > 1) {
	    carp "punlock: count ($count) exceeded lock count (1)";
	    $count = 1;
	}
        _writebyte($fh,$lu,STATE_NULL);
        close $fh;
	$DEBUG && print STDERR
	    "Archy: unlock successful \@ $lu. New state NULL\n";
        return 1;
    }
    close $fh;
    carp "Patro::Archy: punlock called on $obj monitor without lock";
    $! = FAIL_INVALID_WO_LOCK;
    return;
}

sub pwait {
    my ($obj, $id, $timeout) = @_;
    my $lu = _lookup($id);
    my $addr = _addr($obj);
    my $expire = $timeout > 0 ? time + $timeout : 9E19;

    # !!! pwait must remove all stacked locks
    if (!punlock($obj,$id)) {
        return;
    }
    my $fh;
    open($fh,'+<',"$DIR/$addr") || open($fh,'+>', "$DIR/$addr") || die;
    flock $fh, LOCK_EX;
    _writebyte($fh,$lu,STATE_WAIT);
    close $fh;

    my $left = $expire - time;
    while ($left > 0) {
	$threads::threads ? threads->yield : sleep 1;

        open $fh, '+<', "$DIR/$addr";
        flock $fh, LOCK_EX;
        my $ch = _readbyte($fh,$lu);
        close $fh;
        $left = $expire - time;

        if ($ch == STATE_NOTIFY) {    # got notify
	    open $fh, '+<', "$DIR/$addr";
	    flock $fh, LOCK_EX;
	    _writebyte($fh,$lu,STATE_NULL);
	    close $fh;
	    $left = $expire - time;
	    if ($left <= 0 || ($timeout && $timeout < 0)) {
		$left = -1;
	    }
            return plock($obj,$id,$left);
        }
	last if $timeout && $timeout < 0;
    }

    # !!! what state should the monitor be left in when a
    # !!! wait call times out?
    
    $! = FAIL_EXPIRED;
    return;
}

sub pnotify {
    my ($obj, $id, $count) = @_;
    $count ||= 1;
    my $lu = _lookup($id);
    my $addr = _addr($obj);

    my $fh;
    open($fh,'+<',"$DIR/$addr") || open($fh,'+>', "$DIR/$addr") || die;
    flock $fh, LOCK_EX;
    seek $fh, 0, SEEK_END;
    my $sz = tell($fh);

    # assert that this monitor holds the resource
    my $ch = _readbyte($fh,$lu);
    if ($ch < STATE_LOCK) {
	carp "Patro::Archy: pnotify called on $obj monitor without lock";
	$! = FAIL_INVALID_WO_LOCK;
	return;
    }

    my @y1 = (0 .. $sz-1);
    my @y = splice @y1, int($sz * rand);
    push @y, @y1;
    my $notified = 0;
    foreach my $y (@y) {
        $ch = _readbyte($fh,$y);
        if ($ch == STATE_WAIT) {
            _writebyte($fh,$y,STATE_NOTIFY);
	    last if ++$notified >= $count && $count > 0;
        }
    }
    close $fh;
    return $notified || "0 but true";
}


# extract the $n-th byte from filehandle $fh
sub _readbyte {
    my ($fh,$n) = @_;
    my $b = "\n";
    seek $fh, $n, SEEK_SET;
    my $p = read $fh, $b, 1;
    my $ch = $p ? ord($b) : 0;
    if ($DEBUG) {
	print STDERR "Archy:     readbyte($n) = $ch\n";
    }
    return $ch;
}

# update the $n-th byte of filehandle $fh with chr($val)
sub _writebyte {
    my ($fh,$n,$val) = @_;

    if ($n > -s $fh) {
	# extend the file so that we can write to byte $n
	my $newlen = $n - (-s $fh);
        seek $fh, 0, SEEK_END;
        print $fh "\0" x $newlen;
	if ($DEBUG) {
	    print STDERR "Archy:     extend($newlen)\n";
	}
    }
    seek $fh,0,0;
    my $z1 = seek $fh, $n, 0;
    my $z2 = print $fh chr($val);
    if ($DEBUG) {
	print STDERR "Archy:     writebyte($n,$val)\n";
    }
    $z2;
}

sub _readall {
    my ($fh) = @_;
    my $buffer = '';
    seek $fh, 0, SEEK_SET;
    read $fh, $buffer, 32678;
    if ($DEBUG) {
	print STDERR "Archy:     readall => [",
	    join(" ",map ord,split(//,$buffer)), "]\n";
    }
    return $buffer;
}

1;

=head1 NAME

Patro::Archy - establish norms about exclusive access to references

=cut

# This is not necessarily just for Patro-proxy objects

=head1 DESCRIPTION

At times we want threads and processes to have exclusive access to
some resources, even if they have to wait for it. The C<Patro::Archy>
provides functions to request exclusive access to a resource and to
relinquish control of the resource. It also implements an additional
wait/notify feature.

The functions of C<Patro::Archy> all take the same two first
arguments: a reference -- the resource that will be used exclusively
in one thread or process, and an id that uniquely identifies a
thread or process that seeks exclusive access to a resource.

Like most such locks in Perl,
the locks from this package are advisory -- they will only
prevent access to the resource 


=head1 FUNCTIONS

=head2 plock

=head2 $status = plock($object, $id [, $timeout])

Attempts to acquire an exclusive (but advisory) lock on the
reference given by C<$object> for a monitor identified by
C<$id>. Returns true if the lock was successfully acquired.

The monitor id C<$id> is an arbitrary string that identifies
the thread or process that seeks to acquire the resource.
In this function and in the other public functions of
C<Patro::Archy>, there is an implementation limitation
that the monitor id be no more than 20 characters.

If a positive C<$timeout> argument is provided, the function
will give up trying to acquire the lock and return false after
C<$timeout> seconds. If C<$timeout> is negative, the function
call will be treated as a I<non-blocking> lock call, and the
function will return as soon as it can be determined whether
the lock is available.

It is acceptable to call C<plock> for a monitor that already
possesses the lock. Successive lock calls "stack", so that you
must call L<"punlock"> the same number of times that you called
C<plock> on a reference (or provide a C<$count> argument to
L<"punlock">) before it will be released.


=head2 punlock

=head2 $status = punlock($object, $id[, $count])

Releases the lock on reference C<$object> held by the monitor
identified by C<$id>. Returns true on success. A false return
value generally means that the monitor did not have possession
of the lock at the time of the C<punlock> call.

A positive C<$count> argument, if provided, will apply the
unlock operation C<$count> times. Since lock calls from the
same monitor "stack" (see L<"plock">), it may be necessary to
apply the unlock operation more than once to release control of
the reference. A negative C<$count> argument will
release control of the reference unconditionally.


=head2 pwait

=head2 $status = pwait($object, $id [, $timeout])

Releases the lock on reference C<$object> and waits for the
L<"pnotify"> function to be called from another monitor.
After the L<"pnotify"> call is received by the monitor,
the monitor will attempt to acquire the lock on the resource
again. The monitor is only supposed to call this function
when it is in possession of the lock.

Returns true after the lock has been successfully acquired.
Returns false if the function is called while the monitor
does not have the lock on the resource, or if C<$timeout>
is specified and it takes longer than C<$timeout> seconds
to acquire the lock.

=head2 pnotify

=head2 $status = pnotify($object, $id [, $count])

Causes one or more (depending whether C<$count> is specified)
monitors that have previously called L<"pwait"> to wake up and
attempt to reacquire the lock on the resource. The monitor
is supposed to call this function while it is in possession
of the lock. Note that this call does not release the
resource. Returns true on success.



=head1 TODO

All functions should return true on success

$count argument in unlock function





synchronization

we want threads and processes to have exclusive access
to some resources, even if they have to wait for it.

A "monitor" (associated with a particular resource in a
particular thread/process). At most one monitor can have
a "lock" on a resource at a time. A monitor is in one of
three states:

    NULL: does not have a lock on the resource
    LOCK: has the lock on the resource
    WAIT: recently had the lock on the resource and it waiting
          for another monitor to call "notify"

Monitors can make requests about resource access

    lock - request exclusive access to the resource
    - optional parameters: timeout, non-blocking
    - not valid unless called from state NULL

    unlock - relinquish access to the resource
    - all monitors of a thread/process should unlock all
      resources when the thread/process exits
    - should no-op unless called from state LOCK

    wait - relinquish access to the resource. wait for "notify"
           and then try to get access to the resource again
    - optional parameters: timeout
    - not valid unless called from state LOCK

    notify - call "notify" on up to _count_ other monitors
             currently in the wait mode
    - optional parameter: count

The resource manager receives and responds to requests from
monitors. The resource manager should be run in a single
thread or should be synchronized itself.

    on lock request:
        if resource is assigned:
            if request is non-blocking: return EXPIRED
            put request in the lock queue
            if request is timed, set an alarm
        if resource is unassigned:
            assign resource to the monitor making the request
            change monitor state to LOCK
            return SUCCESS

    on unlock request
        change monitor's state to NULL
        unassign the resource
        foreach request in the lock queue:
            if request has expired: return EXPIRED to that monitor
            assign resource to the request's monitor
            change request's monitor state to LOCK        

    on wait request:
        change monitor state to WAIT
        unassign the resource
        put the request on the wait queue
        work the lock queue like you would after an unlock request

    on notify request:
        for 1 to count:
            move a request from the wait queue to the lock queue

    from time to time:
        find expired requests in the lock queue and wait queue
            and return EXPIRED to their respective monitors

The more I think about, the more I see that the resource monitor
cannot be its own thread. Each thread must act as its own
resource monitor, locking out the others, doing its lock maintenance
as quickly as possible, and relinquishing the mutex.


In fact, I view the synchronization implementation as requiring
two synchronization elements.

1. a simple but reliable mutex. Maybe a semaphore -or- file lock
   on the shared memory that governs the resource.

2. a shared data structure -- shared memory or an external file, as
   the data cannot live inside any single process -- with wait queue
   information.

I'm going to revise my view again. The data structure needs to hold
a list of wait events that indicate

1. the thread/process identifier of the waiting monitor, and
2. a flag to indicate if the monitor has been notified (and waiting
   for the correct monitor to notice)

Heck, instead of a flag, you can have a byte that keeps track
of the state of each monitor:

   0 = not used because writebyte($n,0) doesn't work?
   1 = not waiting
   2 = waiting
   3 = notified, or seeking lock
   4 = has lock

Each monitor knows when its operation expires, if it does,
so there is no need for that information in the shared data.

=cut


