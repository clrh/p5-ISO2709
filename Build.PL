use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'ISO2709',
    license             => 'perl',
    dist_author         => 'Marc Chantreux <marc.chantreux@biblibre.com>',
    dist_version_from   => 'lib/ISO2709.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'ISO2709-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
