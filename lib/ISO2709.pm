#! /usr/bin/perl
package ISO2709;
use 5.10.0;
use utf8;
use strict;
use warnings;
# use Devel::SimpleTrace;
use YAML;
use Moose;
our $VERSION = '0.01';

our %Converter = (
    marc8 => sub {
	use MARC::Charset qw< marc8_to_utf8 >;
	$_ = marc8_to_utf8($_)
    },
    iso6937 => sub {
	use Text::Iconv;
	state $iconv = Text::Iconv->new(qw< iso6937 utf8 >);
	$_ = $iconv->convert($_);
    },
    iso5426 => sub {
	use C4::Charset;
	$_ = C4::Charset::char_decode5426($_);
    },
);

has fd => qw< isa FileHandle is rw >;

my %matches = (
    leader => qr{
	    ^
	    \x1d ? 
	    [ \x00\x0a\x0d\x1a]*  # illegal garbage that sometimes occurs between records
	    (
		( \d{5} ) .{7}
		( \d{5} ) .{7}
	    )
    }x
    , dirent => qr{
	    \G
	    ( [0-9A-Za-z]{3} ) 
	    ( \d{4} )
	    ( \d{5} )
    }x
    , subfield => qr{
	\G \x1f
	( [^\x1f] )   # the subfield name 
	( [^\x1f]+ )  # the subfield value
    }x
);

my %separator = (
    field =>  "\x1e"
);

sub _read_field {
    my $fd = shift;
    local $/ = $separator{field};
    <$fd>;
}

sub _data_field {
    my ($raw,$callback) = @_;
    # TODO: keep the separator and verify
    # at the end of parsing

    $raw =~ s/\x1e$//;
    $raw =~ /(.)(.)/g or die;
    my %field = ( ind => [ $1, $2 ] );
    my @data;

    if ( $callback ) {
	while ( $raw =~ /$matches{subfield}/g ) {
	    my $key = $1;
	    local $_ = $2;
	    $callback->();
	    push @data, [ $key, $_ ];
	}
    } else {
	while ( $raw =~ /$matches{subfield}/g ) {
	    push @data, [ $1 , $2 ];
	}
    }

    $field{data} = \@data;
    \%field;
}

sub _control_field {
    local $_ = shift;
    s/\x1e$//;
    if ( my $callback = shift ) { $callback->() }
    { control => $_ };
}

sub in {
    my ($self,$filename) = @_;
    open my $fh, $filename or die "$!";
    $self->fd($fh);
    $self;
}

sub next {
    my ( $self , $callback ) = @_;
    my $fd = $self->fd;
    my $raw = _read_field($fd)
	or return undef
    ;
    my $leader = do {
	if ( $raw =~ m[$matches{leader}]g ) {
	    { complete => $1
	    , size1 => $2
	    , size2 => $3
	    };
	} else {
	    $raw eq "\x1d" and return undef;
	    die Dump
	    { raw => $raw
	    , error => "no leader found "
	    }; 
	}
    };

    my @fields;
    my $end;
    while ( $raw =~ m[$matches{dirent}]g ) {
	my $tag = $1;
	$end = pos($raw);
	my $raw_field = _read_field($fd);

	my $subfields = $tag < 10
	    ? _control_field( $raw_field, $callback )
	    : _data_field( $raw_field, $callback )
	; 

	if ( $subfields ) {
	    $$subfields{tag} = $tag;
	    push @fields, $subfields;
	}

	# push @directory,
	# { tagno  => $1
	# , len    => $2
	# , offset => $3
	# };
    }

    # the position where nothing matches must be
    # the end of field. ensure that:
    if ( $separator{field} ne substr $raw, $end, 1 ) {
	die Dump(
	    { raw => $raw
	    , end => substr $raw, $end
	    }
	), "is not correct";
    }

    { leader    => $leader
    , fields => \@fields
    }

}

sub simple_record {
    my ( $self, $callback ) = @_;
    my $complete = $self->next($callback);
    my $simple = {
	meta => {
	    gpd => { encoding => 26 }
	    , is_biblio => 1
	    , leader => $$complete{leader}{complete} || return undef
	}
    };
    for my $field ( @{ $$complete{fields} } ) {
	if ( $$field{data} ) {
	    my $becomes = {};
	    for ( @{ $$field{data} || [] } ) {
		my ( $key, $value ) = @$_;
		push @{ $$becomes{$key} }, $value;
	    }
	    push @{ $$simple{ $$field{tag} } }, $becomes;
	} else { $$simple{ $$field{tag} } = $$field{control} }
    }
    bless $simple,'SimpleRecord';
}

sub _marc_field {
    my ( $tag, $data ) = @_;
    my @values = map {
	my $code = $_; 
	if ( defined $$data{$code} ) {
	    if ( 'ARRAY' ne ref $$data{$code} ) {
		die Dump
		{ code => $code
		    , data => $data
		    , what => "this is not a hash at " . __FILE__ . " line " . __LINE__
		}
	    }
	    @{ $$data{$code} }
		?  map { $code => $_ } @{ $$data{$code} } 
		: ()
	} else { () }
    } sort keys %$data;
    if (@values) {
	my $field = eval { MARC::Field->new( $tag, (' ')x2, @values ) };
	$@ and die Dump { error => $@, data => $data };
	$field;
    } else { undef }
}


sub SimpleRecord::record {
    my ($simple) = @_;
    my $r = MARC::Record->new;
    $$r{_leader} = $$simple{meta}{leader};
    for my $tag ( sort keys %$simple ) {
	next if $tag eq 'meta';
	my $fields = $$simple{$tag} or next;
	if ( 'ARRAY' ne ref $fields ) {
	    if ( $tag < 10 ) { $r->append_fields( MARC::Field->new( $tag, $fields ) ) }
	    else { die Dump
		{ fields => $fields
		    , tag    => $tag
		    , what   => 'must be an ARRAYREF'
		    , where  => 'while building record from simplerecord at '
			. __FILE__
			. ' line '
			. __LINE__
		}
	    }
	} else {
	    for ( @$fields ) {
		$r->append_fields( _marc_field($tag,$_) or next )
	    }
	}
    }
    $r;
}


no Moose;
1;
