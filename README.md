<div align="center">

# mojo-html

**Liberal HTML parsing and readability-style text extraction in pure Mojo. No Python dependencies, no FFI.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Mojo](https://img.shields.io/badge/Mojo-1.0.0b3%2B_nightly-orange?style=flat-square)](https://mojolang.org)
[![Podcast](https://img.shields.io/badge/Podcast-Chain_of_Thought-purple?style=flat-square)](https://chainofthought.show)
[![X](https://img.shields.io/badge/X-@ConorBronsdon-black?style=flat-square&logo=x)](https://x.com/ConorBronsdon)

</div>

As of mid-2026 the Mojo ecosystem had no library for parsing HTML or pulling
clean article text out of a page. mojo-html fills that gap: a liberal HTML
tokenizer and a readability-style extraction layer on top of it. The
tokenizer is [mojo-feed](https://github.com/conorbronsdon/mojo-feed)'s
battle-tested liberal XML pull parser, adapted for HTML semantics (void
elements, raw-text elements, unquoted attributes, the entities that matter
for prose). I built it to pull article text out of pages I'm sourcing for
research and Chain of Thought show notes: bring a URL's raw bytes in, get
a title, metadata, and the main-content text out.

## What it handles

- **Tokenizer** (`html.tokenizer.HtmlTokenizer`): pull-based event stream
  (start / end / text / EOF) over an HTML document. Never raises on
  malformed markup in its default liberal mode.
  - void elements (`<br>`, `<img>`, `<meta>`, …) with synthetic end events,
    and `<foo/>` self-closing syntax
  - raw-text elements: `<script>` and `<style>` content is consumed
    literally (a `"</div>"` inside a script won't derail the parse);
    `<title>` and `<textarea>` are raw but entity-decoded
  - unquoted attribute values (`href=foo`), valueless attributes, and
    duplicate attributes (first wins), all lowercased, since HTML names
    are case-insensitive
  - the ~40 named entities that actually show up in article prose plus
    numeric references, with Windows-1252 remapping of the C1 control
    range (`&#147;` → a curly quote) and U+FFFD hardening for invalid
    codepoints
  - encoding normalization: UTF-16 BOMs, UTF-8 BOM stripping, encoding
    sniffed from `<meta charset>`, Latin-1/CP1252 transcoding, and lossy
    UTF-8 recovery so mojibake never propagates
  - `strict=True` mode that reports mismatched/stray/unclosed tags and bad
    entities with line/column locations (for linting HTML you produce, not
    for pages you consume)
- **Extractor** (`html.extract.extract`): one pass over the event stream
  with an open-element stack and nearest-match recovery, so unclosed
  `<p>`/`<li>` and crossed tags degrade gracefully. Returns a `Page`:
  `title` (from `<title>`, falling back to `og:title`), `meta_description`
  (`name=description` or `og:description`), `canonical_url`
  (`link rel=canonical`), `lang` (`<html lang>`), block-aware readable
  `text`, `headings` (h1–h6), and `links` (`href` + text).
- **`main_text(source)`**: readability-style main-content scoring. Builds
  a compact node tree in one streaming pass, drops boilerplate subtrees
  (script/style/nav/aside/footer/form/svg/… and ARIA
  `role=navigation|complementary|dialog|…`), then scores paragraph-like
  nodes (`p`, `td`, `pre`, `section`, `h2`–`h6`, and the highest-leverage
  rule, any `<div>` with no block-level children) against class/id
  keyword tables (positive: `content`, `article`, `post`, …; negative:
  `sidebar`, `comment`, `ad-`, …), propagates scores up the ancestor
  chain, and discounts each candidate by its link density. A fast path
  short-circuits scoring when exactly one `<article>`/`<main>`/
  `[role=main]` region exists with substantial text.
- **`main_text_confident(source)`**: same extraction, plus a `confident`
  flag that's false when the winning text is under 140 characters or
  scores under 20, a gate for paywall stubs and other thin pages, so
  callers can tell "no real content here" apart from a confident
  extraction instead of trusting a stub.
- 63 tests across the tokenizer and extractor, run against five real
  fixture pages, plus a fuzz runner that feeds arbitrary/broken HTML
  through both `extract` and `main_text_confident` looking for crashes.

## What it deliberately does NOT do

- **No JavaScript, no CSS, no network.** Pages that render client-side
  yield whatever's in the initial HTML; bring your own bytes.
- **No full HTML5 tree construction.** The tokenizer emits a flat event
  stream; the extraction layer recovers structure with a nearest-match
  stack instead of the spec's insertion modes and adoption-agency
  algorithm. Right trade for text extraction, wrong one for round-tripping
  documents.
- **Single-winner extraction.** The scorer returns one subtree, with no
  sibling-merge step to stitch in adjacent same-parent blocks. A page
  whose content is split across sibling containers returns only the
  densest one.
- **Readability's keep-anyway override isn't applied.** The upstream
  `okMaybeItsACandidate` list only guards a per-node removal pass this
  port omits: boilerplate here is pruned by tag/role drop-set and
  down-weighted by class/id keywords, not deleted node-by-node, so
  porting that list to the class-weight step would do nothing.

## Install

With [pixi](https://pixi.prefix.dev):

```bash
pixi install
pixi run test
```

Or with uv:

```bash
uv venv
uv pip install mojo --index https://whl.modular.com/nightly/simple/ --prerelease allow
.venv/bin/mojo run -I src test/test_extract.mojo
```

Requires a Mojo nightly (`>=1.0.0b3`).

## Usage

```mojo
from html import extract
from html import main_text_confident

def main() raises:
    var source = open("page.html", "r").read()
    var page = extract(source.copy())
    print(page.title)
    print(page.meta_description)
    for link in page.links:
        print(link.href, "->", link.text)

    var main = main_text_confident(source^)
    if main.confident:
        print(main.text)
    else:
        print("thin page, skipping")
```

## Tests

```bash
pixi run test
```

63 tests across the tokenizer and extraction layer, run against five real
captured pages in `test/data/`: a Substack article, example.com, a Paul
Graham essay (genuine 1990s-style tag soup), a docs.python.org tutorial
page (high link density), and a danluu.com article (minimal markup, no
class hints). `test/fuzz_runner.mojo` runs `extract` and
`main_text_confident` over 400+ mutated documents with zero crashes:
malformed input either parses liberally or raises a clean error.

## Part of the Mojo content-tooling suite

- [mojo-feed](https://github.com/conorbronsdon/mojo-feed): RSS, Atom, and
  JSON Feed parsing.
- [mojo-captions](https://github.com/conorbronsdon/mojo-captions): SRT and
  WebVTT subtitle/transcript parsing.
- mojo-markdown (coming soon).

## Contributing

Issues and PRs welcome, especially real-world pages that extract wrong
(attach the URL or a snippet) and sibling-merge cases the scorer misses.
Run `pixi run test` before sending a PR.

## About

Built by [Conor Bronsdon](https://conorbronsdon.com) — host of
[Chain of Thought](https://chainofthought.show), a podcast about AI agents,
infrastructure, and engineering. This library exists to pull clean article
text out of pages I'm sourcing for research and show notes. Find me on
[X](https://x.com/ConorBronsdon) or
[LinkedIn](https://www.linkedin.com/in/conorbronsdon).


---

## Disclaimer

*All views, opinions, and statements expressed on this account/in this repo are solely my own and are made in my personal capacity. They do not reflect, and should not be construed as reflecting, the views, positions, or policies of Modular. This account is not affiliated with, authorized by, or endorsed by my employer in any way.*

## License

Licensed under the [MIT License](LICENSE).
