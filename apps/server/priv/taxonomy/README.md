# Topic taxonomy

`iab-content-taxonomy-3.1.tsv` is the **IAB Tech Lab Content Taxonomy v3.1**, copied unmodified from
<https://github.com/InteractiveAdvertisingBureau/Taxonomies> (`Content Taxonomies/Content Taxonomy 3.1.tsv`).

It is © IAB Technology Laboratory, Inc. and licensed under the
[Creative Commons Attribution 3.0 License](https://creativecommons.org/licenses/by/3.0/).
T-Spec seeds its `topics` table from tiers 1 and 2 of this file (migration `*_create_topics.exs`).
Slugs are derived from names; the IAB unique ID is kept in `topics.iab_id`.

To adopt a newer taxonomy version, add the new file and a new data migration — never edit this one,
since existing `content_topics` and affinities reference the topics it created.
