#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.016;
use autodie qw(:file);
use open qw(:utf8 :std);

use DBI;
use YAML::XS qw(LoadFile);

##################################################################################
# Put the cached Svensk runbibliografi data into a mockup of K-samsök's UGC hub. #
##################################################################################

# Get configuration info:
my %conf = %{LoadFile('../config/config.yml')} or die "Failed to read config file: $!\n";
my $rundsn = "DBI:$conf{dsn}{dbms}:database=$conf{dsn}{database};host=$conf{dsn}{hostname};port=$conf{dsn}{port}";
my $rundbh = DBI->connect($rundsn, $conf{dsn}{username}, $conf{dsn}{password}, {RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1, pg_server_prepare => 1});

my $ugcdsn = "DBI:$conf{dsn}{dbms}:database='ugc';host=$conf{dsn}{hostname};port=$conf{dsn}{port}";
my $ugcdbh = DBI->connect($ugcdsn, $conf{dsn}{username}, $conf{dsn}{password}, {RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1, pg_server_prepare => 1});

# Get signa and corresponding FMIS-ids:
my %signa;
my $runsth = $rundbh->prepare(q{
SELECT signum1, signum2, fmisid
FROM objects_signa_unique JOIN object_nmr_se USING (objectid) JOIN nmr_se USING (nmr_seid)
WHERE fmisid IS NOT NULL
ORDER BY objectid
});
$runsth->execute();
while (my $record = $runsth->fetchrow_arrayref) {
	push(@{$signa{join(' ', @$record[0,1])}}, $record->[2]);
}

# Get bibliographic data:
my @lit = @{ [LoadFile(join('', $conf{path}, 'srb-lit.yml'))] } or die "Failed to read SRB-lit file: $!\n";

my $querysth = $ugcdbh->prepare(q{
SELECT contentid
FROM content
WHERE objecturi = ? AND relatedto = ?
});

my $insertsth = $ugcdbh->prepare(q{
INSERT INTO content (objecturi, username, applicationid, relationtype, relatedto, comment) values (?,'carwash',2,'isDescribedBy',?,'Data från Samnordisk runtextdatabas och Svensk runbibliografi')
});

open (my $SQL, '>', './srb-lit-ugc.sql');
for my $record (@lit) { # For each record (work)…
	next unless ((exists $record->{signa}) && (exists $record->{urls})); # Skip the work if it has no signa or URLs…
	for my $signum (@{$record->{signa}}) { # For each signum that work concerns…
		next unless (exists $signa{$signum}); # Skip the signum if it is not in FMIS…
		for my $uri (@{$record->{urls}}) { # For each URL the work is associated with…
			next unless ($uri =~ m|^http://libris\.kb\.se/bib/|); # Skip the URL if it's not a Libris URI…
			for my $fmisid (@{$signa{$signum}}) { # For each FMIS id this signum has…
				my @found;
				$querysth->execute(join('', 'http://kulturarvsdata.se/raa/fmi/', $fmisid), $uri);
				while (my $contentid = $querysth->fetchrow_arrayref) {
					push(@found, $contentid->[0]);
				}
				unless (@found > 0) {
					$insertsth->execute(join('', 'http://kulturarvsdata.se/raa/fmi/', $fmisid), $uri);
					say $SQL sprintf(qq{INSERT INTO content (contentid, createdate, objecturi, relationtype, relatedto, username, applicationid, comment) VALUES ((SELECT nextval('content_seq') ), current_timestamp, 'http://kulturarvsdata.se/raa/fmi/%s','isDescribedBy','%s','carwash', 2, 'Data från Samnordisk runtextdatabas och Svensk runbibliografi' ) ;}, $fmisid, $uri);
				}
			}
		}
	}
}
close $SQL;
