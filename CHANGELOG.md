# Changelog

## Unreleased

- New `html.errors` module (exported from the package), following the
  shared mojo-* suite pattern: `line_col(source, offset)` maps a byte
  offset to a 1-based (line, column) pair — the column is the 1-based
  BYTE offset within the line, no UTF-8 decoding — and
  `parse_error(msg, source, offset)` builds an `Error` reading
  `<msg> at line <L>, column <C>: '<snippet>'`, where the snippet is up
  to ~30 bytes of the offending line centered on the column,
  whitespace-trimmed, with `...` where truncated, and never multi-line.
- Strict-mode tokenizer errors now carry that position + snippet
  (previously a bare `(line L, column C)` suffix with no snippet), with
  more useful offsets: unclosed-element-at-EOF errors point at the
  unclosed start tag instead of the end of input, and entity errors
  (unknown entity, bare `&`, malformed numeric reference) point at the
  offending `&` — in text, attribute values, and escapable raw text —
  instead of the tokenizer's position after the run.
- No mechanism change: the tokenizer still `raise`s a plain `Error`, the
  `mojo-html [strict]: ` prefix is unchanged, and existing
  `contains=`-style message checks keep matching. The default liberal
  mode still never raises on malformed markup.

## 0.1.0 — 2026-07-05

Initial release. Liberal HTML tokenizer (void elements, raw-text
elements, unquoted attributes, entity decoding, encoding normalization,
optional strict diagnostics) plus a readability-style extraction layer
(`extract`, `main_text`, `main_text_confident`) returning title, meta
description, canonical URL, language, block-aware text, headings, and
links. 63 tests across the tokenizer and extractor, run against five
real fixture pages, plus a fuzz runner covering 400+ mutated documents
with zero crashes.
