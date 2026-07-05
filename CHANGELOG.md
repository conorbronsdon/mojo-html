# Changelog

## 0.1.0 — 2026-07-05

Initial release. Liberal HTML tokenizer (void elements, raw-text
elements, unquoted attributes, entity decoding, encoding normalization,
optional strict diagnostics) plus a readability-style extraction layer
(`extract`, `main_text`, `main_text_confident`) returning title, meta
description, canonical URL, language, block-aware text, headings, and
links. 63 tests across the tokenizer and extractor, run against five
real fixture pages, plus a fuzz runner covering 400+ mutated documents
with zero crashes.
