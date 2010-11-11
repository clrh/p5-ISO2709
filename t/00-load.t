#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'ISO2709' );
}

diag( "Testing ISO2709 $ISO2709::VERSION, Perl $], $^X" );
