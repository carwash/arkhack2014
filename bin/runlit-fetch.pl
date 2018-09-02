#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.016;
use autodie qw(:file);
use threads;
use open qw(:utf8 :std);

use DBI;
use Digest::SHA3 qw(sha3_224_hex);
use HTML::TreeBuilder::XPath;
use MCE::Loop chunk_size => 'auto', max_workers => 'auto';
use URI::Escape qw(uri_escape);
use WWW::Mechanize;
use YAML::XS qw(DumpFile LoadFile);

#################################################################################
# Scrape the Svensk Runbibliografi for bibliographic data and links, by signum. #
# (I checked their robots.txt, and they seem to be cool with that.)             #
#################################################################################

# Initialise a hash to hold all the bibliographic details (keys are SHA3-hashed concatenation of title, author, year):
my %bib;

MCE::Loop::init {
	gather => sub { accession(@_, \%bib) }
};

mce_loop {
	for (@{$_}) {
		MCE->gather(browse_listing($_));
	}
} list_signa();
MCE::Loop::finish;

#for (list_signa()) {accession(browse_listing($_), \%bib)} # Non-MCE version, for testing.

# Clean up URLs:
fix_urls(\%bib);

# Serialise unique list of works to YAML:
print 'Dumping results to file… ';
my %conf = %{LoadFile('../config/config.yml')} or die "Failed to read config file: $!\n";
DumpFile(join('', $conf{'path'}, 'srb-lit.yml'), values %bib) or die "Failed to write output file: $!\n";
say 'done.';
# Exeunt omnes, laughing.


#################################################################################


# Query the database for all runic signa, ancient and modern:
sub list_signa {
	print 'Gathering list of signa… ';
	# Get configuration info:
	my %conf = %{LoadFile('../config/config.yml')} or die "Failed to read config file: $!\n";
	my $dsn = "DBI:$conf{dsn}{dbms}:database=$conf{dsn}{database};host=$conf{dsn}{hostname};port=$conf{dsn}{port}";
	my $dbh = DBI->connect($dsn, $conf{dsn}{username}, $conf{dsn}{password}, {RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1, pg_server_prepare => 1});

	my @signa;
	my $sth = $dbh->prepare(q{
SELECT signum1, signum2
FROM objects_signa_unique
});
	$sth->execute();
	while (my $record = $sth->fetchrow_arrayref) {
		push(@signa, join(' ', @{$record}));
	}
	say 'done.';
	return (@signa);
}


# Request a listing of results for each signum, find the first, and pass its URL off to browse_results():
sub browse_listing {
	my $signum = shift;
	my $mech = WWW::Mechanize->new();
	my $search_uri = join('', q{http://fornsvenskbibliografi.ra.se/pub/views/runbibl/hitlist.aspx?ccl=find%20runsig%20}, uri_escape($signum));
	$mech->get($search_uri);
	unless ($mech->success()) {
		warn "Could not fetch results page for '$signum'; returned status $mech->status()\n";
		return(0, $signum);
	}
	my $tree = HTML::TreeBuilder::XPath->new_from_content($mech->content());
	if ($tree->exists(q{//div[@id='ctl00_cphContent_pnlMessageTop']}) &&
	    ($tree->findvalue(q{//div[@id='ctl00_cphContent_pnlMessageTop']}) eq ' Din sökning gav inga träffar. ')) {
		$tree->delete;
		return(0, $signum); # No results. :(
	}
	elsif ($tree->exists(q{//table[@id='ctl00_cphContent_gwHitList']})) {
		if (my $hit = $mech->find_link(class => 'hitnumber', text => '1')) {
			$tree->delete;
			my $records; # Hashref of records for this signum.
			return(browse_results($signum, $records, $mech, $hit));
		}
		else {
			warn "Could not locate first result link for '$signum', <" . $mech->uri()->as_string() . ">\n";
			$tree->delete;
			return(0, $signum);
		}
	}
	else {
		warn "No 'no hits' message, but no result listing either, for '$signum'. :/\n"; # WTF?
		$tree->delete;
		return(0, $signum);
	}
}


# Request a result URL, check it for validity, pass the content off for recording and line up the next result for processing:
sub browse_results {
	my ($signum, $records, $mech, $hit) = @_;
	while (1) {
		$mech->add_header(Referer => $mech->uri()->as_string());
		$mech->get($hit);
		unless ($mech->success()) {
			warn "Could not fetch hit page for '$signum'; returned status " . $mech->status() . "\n";
			return(0, $signum);
		}
		my $tree = HTML::TreeBuilder::XPath->new_from_content($mech->content());
		if ($tree->exists(q{//div[@id='ctl00_cphContent_pnlMessageTop']}) &&
	    	($tree->findvalue(q{//div[@id='ctl00_cphContent_pnlMessageTop']}) eq ' Input string was not in a correct format. ')) {
			warn "No referer for '$signum', <" . $mech->uri()->as_string() . ">\n";
			$tree->delete;
			return(0, $signum);
		}
		elsif (!$tree->exists(q{//div[@id='ctl00_cphContent_pnlShowRecord']/table})) {
			warn "Unable to locate record table for '$signum', <" . $mech->uri()->as_string() . ">\n";
			$tree->delete;
			return(0, $signum);
		}
		else {
			my $signa = $tree->findvalue(q{//div[@id='ctl00_cphContent_pnlShowRecord']/table/tr[@id='RUNSIG']/td[@class='fieldContents']/div});
			if ($signa =~ m/\s$signum;?\s/) { # Are these results actually accurate – is the sought signum really described by this work? (I'm looking at you, Orcadian inscriptions!)
				($signum, $records) = extract_fields($signum, $records, $tree);
			}
			if ($tree->exists(q{//span[@id='ctl00_cphContent_lblResultInfo']})) {
				my $xofy = $tree->findvalue(q{//span[@id='ctl00_cphContent_lblResultInfo']});
				if ($xofy =~ /^(?:Visar|Record) (?<x>\d+) (?:av|of) (?<y>\d+)\.?$/) {
					if ($+{x} >= $+{y}) { # End if this is the last result in the set.
						$tree->delete;
						return(1, $signum, $records);
					}
					$tree->delete;
					$hit = $mech->uri()->as_string();
					$hit =~ s/_(\d+)$/'_' . ($1 + 1)/e; # The next result in the set is this one, +1:
					next;
				}
				else {
					warn "Unable to read record number for '$signum', <" . $mech->uri()->as_string() . ">\n";
					$tree->delete;
					return(0, $signum);
				}
			}
			else {
				warn "Unable to locate record number for '$signum', <" . $mech->uri()->as_string() . ">\n";
				$tree->delete;
				return(0, $signum);
			}
		}
	}
}


# For a given result (work), extract its fields:
sub extract_fields {
	my ($signum, $records, $tree) = @_;
	my %record; # Here we'll temporarily store the record for this work.
	my %fields = (
	              AU    => {
	                        label  => 'authors',
	                        action => \&splitpeople,
	                       },
	              NFIPL => {
	                        label => 'form of name in publication',
	                        action => \&splitpeople,
	                       },
	              ED    => {
	                        label  => 'editors',
	                        action => \&splitpeople,
	                       },
	              TI    => {
	                        label => 'title',
	                        action => sub {return(trim(shift))},
	                       },
	              VT    => { # Seems now no longer to occur, but safest to keep this here.
	                        label => 'title of work',
	                        action => sub {return(trim(shift))},
	                       },
	              PUBF  => { # Seems to occur only once, for the record of <http://libris.kb.se/resource/bib/12102929>
	                        label => 'object of publication',
	                        action => sub {return(trim(shift))},
	                       },
	              YEAR  => {
	                        label => 'year',
	                        action => sub {return(trim(shift))},
	                       },
	              ING   => {
	                        label => 'part of',
	                        action => sub {return(trim(shift))},
	                       },
	              FOR   => {
	                        label => 'place and publisher',
	                        action => sub {
		                        my $value = trim(shift);
		                        my %publisher;
		                        @publisher{qw(place publisher)} = split(/\s*:\s*/, $value, 2);
		                        return(\%publisher);
	                        },
	                       },
	              SE    => {
	                        label => 'series',
	                        action => sub {return(trim(shift))},
	                       },
	              VOL   => {
	                        label => 'volume',
	                        action => sub {return(trim(shift))},
	                       },
	              PUB   => {
	                        label => 'type of publication',
	                        action => sub {return(trim(shift))},
	                       },
	              PAG   => {
	                        label => 'pages',
	                        action => sub {return(trim(shift))},
	                       },
	              KOM   => {
	                        label => 'comments',
	                        action => sub {return(trim(shift))},
	                       },
	              REC   => {
	                        label => 'review',
	                        action => sub {return(trim(shift))},
	                       },
	              UPL   => {
	                        label => 'edition',
	                        action => sub {return(trim(shift))},
	                       },
	              URL   => {
	                        label => 'urls',
	                        action => sub {
		                        my $value = trim(shift);
		                        $value =~ s/(?<=\S)http:/, http:/g; # Some URLs appear to be run together.
		                        my @uris = grep {m|^http://|} split(/,? +/, $value); # Sometimes there are notes or empty fields.
		                        return(\@uris);
	                        },
	                       },
	             );

	# Iterate over the table rows, and for each get the label as key, contents as value. Skip signa. Then hash them.
	my @fields = $tree->findnodes(q{//div[@id='ctl00_cphContent_pnlShowRecord']/table/tr});
	for (@fields) {
		my $id = $_->attr('id');
		next if (($id eq 'RUNSIG') || ($id eq 'KLASRUN'));
		if (exists $fields{$id}) {
			$record{$fields{$id}{label}} = $fields{$id}{action}->($tree->findvalue(join('', q{//div[@id='ctl00_cphContent_pnlShowRecord']/table/tr[@id='}, $id, q{']/td[@class='fieldContents']/div})));
		}
		else {
			warn "'$signum' features unknown id '$id' in a record.\n";
		}
	}

	# Create a unique hash key (SHA3 hash) for this work:
	my @hashfields = (
	                  (exists $record{authors}) ? join('', map {join('', $_->{surname} // '',  $_->{firstname} // '')} @{$record{authors}}) : '',
	                  (exists $record{year}) ? $record{year} : '',
	                  (exists $record{title}) ? $record{title} : '',
	                  (exists $record{editors}) ? join('', map {join('', $_->{surname} // '',  $_->{firstname} // '')} @{$record{editors}}) : '',
	                  (exists $record{urls}) ? join('', @{$record{urls}}) : ''
	                 );
	for (@hashfields) {utf8::encode($_)} # SHA3 does not like wide characters
	$records->{sha3_224_hex(@hashfields)} = \%record;
	return($signum, $records);
}


# For records (works) of a given signum, add them if they do not already exist, and append the current signum to their records:
sub accession {
	my ($status, $signum, $records, $bib) = @_;
	return(0) if ($status == 0);
	for (keys %{$records}) {
		unless (exists $bib->{$_}) {
			$bib->{$_} = $records->{$_};
		}
		push(@{$bib->{$_}{signa}}, $signum);
	}
	return(1);
}


# For a record concerning multiple people (authors, editors) return a listref of people (hashrefs of firstname/surname):
sub splitpeople {
	my $value = trim(shift);
	my @people;
	for (split(/\s*[;:]\s*/, $value)) {
		my %person;
		@person{qw(surname firstname)} = split(/, ?/, $_, 2);
		push(@people, \%person);
	}
	return(\@people);
}


# Remove whitespace from the beginning and end of a string:
sub trim {
	my $value = shift;
	for ($value) {
		s/^\s+//;
		s/\s+$//;
	}
	return($value);
}


# Remove params from Libris URIs, and replace DiVA URLs with URNs resolved via Kb
sub fix_urls {
	print 'Resolving URNs… ';
	my %bib = %{shift()};
	my %uris; # Original as key, permalink as value

	# Phase 1: Collect URIs
	for my $record (keys %bib) { # For each record (work)…
		next unless (exists $bib{$record}{urls}); # Skip the work if it has no URLs…
		for my $uri (@{$bib{$record}{urls}}) { # For each URL the work is associated with…
			if ((($uri =~ m|^http://libris\.kb\.se/bib/|) &&
			     ($uri =~ m|[?&]|)) ||
			    ($uri =~ m|^http://[a-z]+\.diva-portal.org/smash/|)) {
				$uris{$uri} = undef; # Collect the URL, if it maches our criteria.
			}
		}
	}

	# Phase 2: ?
	for my $uri (keys %uris) {
		if ($uri =~ m|^(?<libris>http://libris\.kb\.se/bib/[^\?&]+).*$|) {
			# Strip params:
			$uris{$uri} = $+{libris};
		}
		elsif ($uri =~ m|^http://[a-z]+\.diva-portal.org/smash/|) {
			if ($uri =~ m|^http://[a-z]+\.diva-portal.org/smash/record\.jsf\?pid=|) {
				# Get the permanent URI:
				$uris{$uri} = resolve($uri);
			}
			elsif ($uri =~ m|^http://(?<divaprovider>[a-z]+)\.diva-portal.org/smash/get/diva2:(?<divaid>[0-9]+)/FULLTEXT01|) {
				# Get the permanent URI (not the PDF!):
				$uris{$uri} = resolve(join('', 'http://', $+{divaprovider}, '.diva-portal.org/smash/record.jsf?pid=diva2:', $+{divaid}));
			}
		}
	}

	# Phase 3: Profit
	for my $record (keys %bib) { # For each record (work)…
		next unless (exists $bib{$record}{urls}); # Skip the work if it has no URLs…
		for my $uri (@{$bib{$record}{urls}}) { # For each URL the work is associated with…
			if (exists $uris{$uri}) {
				$uri = $uris{$uri}; # Replace the URL with a corrected version, where appropriate.
			}
			$uri =~ s|^http://libris\.kb\.se/bib/|http://libris\.kb\.se/resource/bib/|; # Replace Libris URLs with proper Libris URIs
		}
	}
	say 'done.';
}


# For a DiVA URL, return a permanent URL to Kb's URN resolver:
sub resolve {
	my $uri = shift;
	my $mech = WWW::Mechanize->new();
	$mech->get($uri);
	unless ($mech->success()) {
		warn "Could not fetch page for '$uri'; returned status $mech->status()\n";
	}
	my $tree = HTML::TreeBuilder::XPath->new_from_content($mech->content());
	if ($tree->exists(q{/html/head/meta[@name='DC.Identifier.url']})) {
		for ($tree->findvalues(q{/html/head/meta[@name='DC.Identifier.url']/@content})) {
			next unless ($_ =~ m|http://urn\.kb\.se/resolve\?urn=|);
			$uri = $_;
		}
	}
	else {
		warn "Unable to locate permanent URI for '$uri'.\n";
	}
	$tree->delete;
	return $uri;
}
