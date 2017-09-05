package Patro::N5;
use strict;
use warnings;

# Patro::N5. Proxy class for GLOB type references.

# we must keep this namespace very clean
use Carp ();

use overload
    '*{}' => sub { ${$_[0]}->{handle} },
    'nomethod' => \&Patro::LeumJelly::overload_handler,
    ;

# override UNIVERSAL methods
foreach my $umethod (keys %UNIVERSAL::) {
    no strict 'refs';
    *{$umethod} = sub {
	my $proxy = shift;
	my $context = defined(wantarray) ? 1 + wantarray : 0;
	return Patro::LeumJelly::proxy_request( $$proxy,
	    { id => $$proxy->{id}, topic => 'METHOD', command => $umethod,
	      has_args => @_ > 0, args => [ @_ ], context => $context }, @_ );
    };
}

sub AUTOLOAD {
    my $method = $Patro::N5::AUTOLOAD;
    $method =~ s/.*:://;

    my $self = shift;
    my $has_args = @_ > 0;
    my $args = [ @_ ];

    my $context = defined(wantarray) ? 1 + wantarray : 0;

    return Patro::LeumJelly::proxy_request( $$self, 
	{ id => $$self->{id},
	  topic => 'METHOD',
	  command => $method,
	  has_args => $has_args,
	  args => $args,
	  context => $context,
	  _autoload => 1 }, @_ );
}

sub DESTROY {
    my $self = shift;
    if ($$self->{_DESTROY}++) {
	return;
    }
    my $socket = $$self->{socket};
    if ($socket) {

	# XXX - shouldn't disconnect on every object destruction,
	# only when all of the wrapped objects associated with a
	# client have been destroyed, or during global
	# destruction

	my $response = Patro::LeumJelly::proxy_request(
	    $$self,
	    { id => $$self->{id},
	      topic => 'META',
	      #command => 'disconnect' } );
	      command => 'destroy' } );
	if ($response->{disconnect_ok}) {
	    close $socket;
	    delete $$self->{socket};
	}
    }
}

############################################################

sub Patro::Tie::HANDLE::TIEHANDLE {
    my ($pkg,$proxy) = @_;
    return bless { obj => $proxy, id => $proxy->{id} }, $pkg;
}

sub Patro::Tie::HANDLE::__ {
    my $tied = shift;
    my $name = shift;
    my $context = shift;
    if (!defined($context)) {
	$context = defined(wantarray) ? 1 + wantarray : 0;
    }
    return Patro::LeumJelly::proxy_request(
	$tied->{obj},
	{ topic => 'HANDLE',
	  command => $name,
	  context => $context,
	  has_args => @_ > 0,
	  args => [ @_ ],
	  id => $tied->{id} }, @_ );
}

sub Patro::Tie::HANDLE::PRINT { return shift->__('PRINT',1,@_?@_:$_) }
sub Patro::Tie::HANDLE::PRINTF { return shift->__('PRINTF',1,@_?@_:$_) }
sub Patro::Tie::HANDLE::WRITE { return shift->__('WRITE',1,@_) }
sub Patro::Tie::HANDLE::READLINE { return shift->__('READLINE',undef,@_) }
sub Patro::Tie::HANDLE::GETC { return shift->__('GETC',1,@_) }
sub Patro::Tie::HANDLE::READ {
    my $name = 'READ?';
    if ($Patro::sysread_read_flag) {
	if ($Patro::sysread_read_flag eq 'read') {
	    $name = 'READ';
	} elsif ($Patro::sysread_read_flag eq 'sysread') {
	    $name = 'SYSREAD';
	}
    }
    return shift->__($name,1,@_);
}
sub Patro::Tie::HANDLE::CLOSE { return shift->__('CLOSE',1,@_) }
sub Patro::Tie::HANDLE::BINMODE { return shift->__('BINMODE',1,@_) }
sub Patro::Tie::HANDLE::OPEN { return shift->__('OPEN',1,@_) }
sub Patro::Tie::HANDLE::EOF { return shift->__('EOF',1,@_) }
sub Patro::Tie::HANDLE::FILENO { return shift->__('FILENO',1,@_) }
sub Patro::Tie::HANDLE::SEEK { return shift->__('SEEK',1,@_) }
sub Patro::Tie::HANDLE::TELL { return shift->__('TELL',1,@_) }

############################################################

1;
