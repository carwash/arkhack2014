#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.016;
use autodie qw(:file);
use open qw(:utf8 :std);

use DBI;
use RDF::Trine;
use RDF::Trine::NamespaceMap;
use RDF::Trine::Serializer::Turtle;
use YAML::XS qw(LoadFile);

############################################################################################
# Query the SRDB database for signa with FMIS ids;                                         #
# Read in the YAML dump of Svensk runbibliografi, and find all the works with Libris URIs; #
# Iterate over one, and find all matches from the other;                                   #
# Feed these results into an in-memory triplestore;                                        #
# When finished, serialise the graph as Turtle, for later ingest into the UGC hub.         #
############################################################################################

# Get configuration info:
my %conf = %{LoadFile('../config/config.yml')} or die "Failed to read config file: $!\n";
my $dsn = "DBI:$conf{dsn}{dbms}:database=$conf{dsn}{database};host=$conf{dsn}{hostname};port=$conf{dsn}{port}";
my $dbh = DBI->connect($dsn, $conf{dsn}{username}, $conf{dsn}{password}, {RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1, pg_server_prepare => 1});

# Get signa and corresponding FMIS-ids:
my %signa;
my $sth = $dbh->prepare(q{
SELECT signum1, signum2, fmisid
FROM objects_signa_unique JOIN object_nmr_se USING (objectid) JOIN nmr_se USING (nmr_seid)
WHERE fmisid IS NOT NULL
ORDER BY objectid
});
$sth->execute();
while (my $record = $sth->fetchrow_arrayref) {
	push(@{$signa{join(' ', @$record[0,1])}}, $record->[2]);
}

# Get bibliographic data:
my @lit = @{ [LoadFile(join('', $conf{path}, 'srb-lit.yml'))] } or die "Failed to read SRB-lit file: $!\n";

# Create a temporary Triplestore:
my $store = RDF::Trine::Store::Memory->new();
my $model = RDF::Trine::Model->new($store);

# Define namespaces:
my %prefixes = (
                ksam   => 'http://kulturarvsdata.se/ksamsok#',
                fmis   => 'http://kulturarvsdata.se/raa/fmi/',
                libris => 'http://libris.kb.se/bib/',
               );
my $prefixes = RDF::Trine::NamespaceMap->new(\%prefixes);

my $predicate = $prefixes->ksam('isDescribedBy');

$model->begin_bulk_ops();
for my $record (@lit) { # For each record (work)…
	next unless ((exists $record->{signa}) && (exists $record->{urls})); # Skip the work if it has no signa or URLs…
	for my $signum (@{$record->{signa}}) { # For each signum that work concerns…
		next unless (exists $signa{$signum}); # Skip the signum if it is not in FMIS…
		for my $uri (@{$record->{urls}}) { # For each URL the work is associated with…
			next unless ($uri =~ m|^http://libris\.kb\.se/bib/(?<librisid>.+)$|); # Skip the URL if it's not a Libris URI…
			my $librisid = $+{librisid};
			for my $fmisid (@{$signa{$signum}}) { # For each FMIS id this signum has…
				my $triple = RDF::Trine::Statement->new($prefixes->fmis($fmisid), $predicate, $prefixes->libris($librisid)); # Generate a triple…
				$model->add_statement($triple); # …and insert it!
			}
		}
	}
}
$model->end_bulk_ops();

say $model->size . ' triples stored!';

my $turtle = RDF::Trine::Serializer::Turtle->new(namespaces => $prefixes);
# Dump out the whole graph:
open (my $fh, '>', join('', $conf{path}, 'srb-lit-soch.ttl'));
$turtle->serialize_model_to_file ($fh, $model);
close $fh;
