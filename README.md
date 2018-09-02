# ArkHack 2014

Three scripts to connect Swedish runic inscriptions in [SOCH][] with literature written about them from [Libris][], using linked data; intended to enrich [SOCH][]'s user-generated content. Written in brief moments here and there during the [Swedish National Heritage Board][RAÄ]'s [ArkHack 2.0][] in Umeå, April 2014.

---

([Skip to the end…](#output))

The idea was to produce linked data connecting runic inscriptions to the literature describing them, for the user-generated content part of [SOCH][]. There are four main sources of data required for this:

1. [SOCH][], which assigns Swedish monuments and artefacts URIs and harvests metadata about them from, among a variety of sources;
1. [Libris][], which maintains URIs for literary objects;
1. [Svensk runbibliografi][SRB], which contains bibliographic information about works concerning runic inscriptions. For our purposes, we're interested in these works' Libris URIs, and the runic signa of the inscriptions they're about;
1. [Samnordisk runtextdatabas][SRDB], which contain masses of useful information about Scandinavian runic inscriptions but is interesting here only insomuch as it allows us to create a mapping between Swedish inscriptions' runic signa (which Svensk runbibliografi uses) and their SOCH URIs). This enables us to connect monuments and artefacts in SOCH to Libris URIs from Svensk runbibliografi.

The resulting scripts assume the admittedly unlikely scenario that you have a copy of Samnordisk runtextdatabas mapped to a structured, normalised relational database that you can query to get a list of all runic signa and their corresponding SOCH URIs. Creating such a database is [left as an exercise for the reader](http://www.runinskrifter.net/), but without one these scripts are unlikely to be of much use unless you can provide the signa-to-URI mapping by other means. Consequently, the final output of these scripts – [the interesting part!](#output) – is also provided here, so you don't actually have to run them yourself. :)

## `runlit-fetch.pl`

Svensk runbibliografi sadly has no web API or other similar method of directly querying or accessing its data, so the first order of the day is to scrape it and structure the data (yes, their `robots.txt` appears to allow this). [`runlit-fetch.pl`](bin/runlit-fetch.pl) queries Samnordisk runtextdatabas for a complete list of signa, and queries Svensk runbibliografi over the web for details of works pertaining to those inscriptions. Because Svensk runbibliografi does not expose the URLs (*sic*) of its listed works either (everything is addressed indirectly by session-based query URLs) this means that details about the same work are likely to be fetched multiple times. To speed things up, the script is multithreaded, using [MCE][] to do all of this for a number of records in parallel, hashing the results and discarding works which have already been cached. Once it's finished, it outputs the resulting data to [`srb-lit.yml`](cache/srb-lit.yml) for use by the other two scripts. (Nb. this output is not included here due to unclear licensing of the data.)

## `runlit2ksam.pl`

[`runlit2ksam.pl`](bin/runlit2ksam.pl) queries Samnordisk runtextdatabas to create a mapping between runic signa SOCH URIs. It then reads in the cached bibliographic data from [`srb-lit.yml`](cache/srb-lit.yml) and proceeds to filter the data, looking only for works with Libris URIs which concern inscriptions which have SOCH URIs. Using [RDF::Trine](http://www.perlrdf.org/), the resulting assertions are collated as RDF triples in a temporary (in-memory) triplestore before being dumped out as Turtle to [`srb-lit-soch.ttl`](cache/srb-lit-soch.ttl). *Ta-da!*

## `runlit2ugc.pl`

Does exactly the same as `runlit2ksam.pl` except that it assumes that you have access to SOCH's actual UGC hub database (or a reasonable facsimile) and inserts the data there instead, rather than using actual RDF.

## Output

TL;DR, here's-one-I-made-earlier:

**[`srb-lit-soch.ttl`](cache/srb-lit-soch.ttl)** contains the RDF assertions relating runic inscriptions in SOCH to literature in Libris, as Turtle.

## See also:

- <https://github.com/ostagarn/archack2014>

---

## License

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

See <http://www.perl.com/perl/misc/Artistic.html>

[SOCH]: https://www.raa.se/ksamsok
[Libris]: http://libris.kb.se/
[RAÄ]: https://www.raa.se/
[ArkHack 2.0]: http://www.k-blogg.se/2014/04/15/arkhack-2-0/
[SRDB]: http://www.nordiska.uu.se/forskn/samnord.htm
[SRB]: http://fornsvenskbibliografi.ra.se/
[MCE]: https://metacpan.org/pod/distribution/MCE/lib/MCE.pod
