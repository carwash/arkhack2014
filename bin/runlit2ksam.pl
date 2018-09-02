#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.016;
use autodie qw(:file);
use open qw(:utf8 :std);

use DBI;
use RDF::Trine;
use YAML::XS qw(LoadFile);

############################################################################################
# Query the SRDB database for signa with SOCH URIs;                                        #
# Read in the YAML dump of Svensk runbibliografi, and find all the works with Libris URIs; #
# Iterate over one, and find all matches from the other;                                   #
# Feed these results into an in-memory triplestore;                                        #
# When finished, serialise the graph as Turtle, for later ingest into the UGC hub.         #
############################################################################################

# Get configuration info:
my %conf = %{LoadFile('../config/config.yml')} or die "Failed to read config file: $!\n";
my $dsn = "DBI:$conf{dsn}{dbms}:database=$conf{dsn}{database};host=$conf{dsn}{hostname};port=$conf{dsn}{port}";
my $dbh = DBI->connect($dsn, $conf{dsn}{username}, $conf{dsn}{password}, {RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1, pg_server_prepare => 1});

# Get signa and corresponding SOCH URIs:
my %signa;
my $sth = $dbh->prepare(q{
SELECT signum1, signum2, uri
FROM objects_signa_unique JOIN object_uri USING (objectid) JOIN uris USING (uriid)
ORDER BY objectid
});
$sth->execute();
while (my $record = $sth->fetchrow_arrayref) {
	push(@{$signa{join(' ', @$record[0,1])}}, $record->[2]);
}

# Get bibliographic data:
my @lit = @{ [LoadFile(join('', $conf{path}, 'srb-lit.yml'))] } or die "Failed to read SRB-lit file: $!\n";

# Create a temporary Triplestore:
my $store = RDF::Trine::Store->new('Memory');
my $model = RDF::Trine::Model->new($store);

# Define namespaces:
my %prefixes = (
                bbr      => 'http://kulturarvsdata.se/raa/bbr/',
                fmis     => 'http://kulturarvsdata.se/raa/fmi/',
                gsm      => 'http://kulturarvsdata.se/GSM/objekt/',
                ksam     => 'http://kulturarvsdata.se/ksamsok#',
                kulturen => 'http://kulturarvsdata.se/Kulturen/objekt/',
                libris   => 'http://libris.kb.se/resource/bib/',
                nomu     => 'http://kulturarvsdata.se/nomu/object/',
                shm      => 'http://kulturarvsdata.se/shm/object/',
                shmart   => 'http://kulturarvsdata.se/shm/art/',
                slm      => 'http://kulturarvsdata.se/SLM/item/',
                solm     => 'http://kulturarvsdata.se/S-OLM/object/',
                upmu     => 'http://kulturarvsdata.se/upmu/object/',
               );
my $prefixes = RDF::Trine::NamespaceMap->new(\%prefixes);

my $predicate = $prefixes->ksam('isDescribedBy');

$model->begin_bulk_ops();
for my $record (@lit) { # For each record (work)…
	next unless ((exists $record->{signa}) && (exists $record->{urls})); # Skip the work if it has no signa or URLs…
	for my $signum (@{$record->{signa}}) { # For each signum that work concerns…
		next unless (exists $signa{$signum}); # Skip the signum if it does not have a URI…
		for my $uri (@{$record->{urls}}) { # For each URL the work is associated with…
			next unless ($uri =~ m|^http://libris\.kb\.se/resource/bib/(?<librisid>.+)$|); # Skip the URL if it's not a Libris URI…
			my $librisid = $+{librisid};
			for my $soch_uri (@{$signa{$signum}}) { # For each object id this signum has…
				next unless ($soch_uri =~ m!^https?://kulturarvsdata\.se/!); # Skip if not a SOCH URI…
				my $triple = RDF::Trine::Statement->new(RDF::Trine::Node::Resource->new($soch_uri), $predicate, $prefixes->libris($librisid)); # Generate a triple…
				$model->add_statement($triple); # …and insert it!
			}
		}
	}
}
$model->end_bulk_ops();

say $model->size . ' triples stored!';

my $turtle = RDF::Trine::Serializer->new('turtle', namespaces => $prefixes);
# Dump out the whole graph:
open (my $fh, '>', join('', $conf{path}, 'srb-lit-soch.ttl'));
$turtle->serialize_model_to_file ($fh, $model);
close $fh;
