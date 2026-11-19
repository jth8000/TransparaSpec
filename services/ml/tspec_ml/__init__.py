"""T-Spec's content-understanding service (ADR 0003).

Phoenix calls it from Oban jobs only. It is stateless: it reads the media it
is pointed at, returns transcripts, embeddings and per-topic scores, and keeps
nothing. It never returns approve/reject decisions.
"""
