"""Readability-style text and metadata extraction over the tokenizer.

`extract(source)` walks the event stream once and returns a `Page` with
document metadata (title, meta description, canonical URL, language)
plus block-aware readable text, headings, and links.

Structural recovery lives here: nesting is tracked with an
element-name stack, and an end tag matches the *nearest* open element
with its name, implicitly closing anything opened above it — so
unclosed <p>, <li>, and crossed tags degrade gracefully instead of
desyncing the rest of the document. Stray end tags are ignored.

`main_text(source)` is a readability-style scorer. It builds a compact
node tree in one streaming pass, drops boilerplate subtrees
(script/nav/aside/footer/form/svg/...), then scores paragraph-like
elements (p, td, pre, section, h2–h6, and divs with no block children)
by text length, comma count, tag, and class/id keyword weight,
propagating scores to ancestors and discounting by link density. An
<article>/<main>/[role=main] fast path short-circuits when exactly one
such region exists with substantial text. `main_text_confident` also
returns a confidence flag that is false for thin/low-score output
(paywall stubs).
"""

from html.tokenizer import (
    HtmlTokenizer,
    EVENT_START,
    EVENT_END,
    EVENT_TEXT,
    EVENT_EOF,
)


@fieldwise_init
struct Heading(Copyable, Movable, Writable):
    """One h1–h6 heading: `level` is 1–6."""

    var level: Int
    var text: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("h", self.level, ": ", self.text)


@fieldwise_init
struct Link(Copyable, Movable, Writable):
    """One <a href> from the document body."""

    var href: String
    var text: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("[", self.text, "](", self.href, ")")


struct Page(Copyable, Movable):
    """Extracted document metadata and readable text."""

    var title: String
    var meta_description: String
    var canonical_url: String
    var lang: String
    var text: String
    var headings: List[Heading]
    var links: List[Link]

    def __init__(out self):
        self.title = String()
        self.meta_description = String()
        self.canonical_url = String()
        self.lang = String()
        self.text = String()
        self.headings = List[Heading]()
        self.links = List[Link]()


def _is_block(name: String) -> Bool:
    """Elements whose boundaries produce line breaks in extracted text."""
    return (
        name == "p"
        or name == "div"
        or name == "h1"
        or name == "h2"
        or name == "h3"
        or name == "h4"
        or name == "h5"
        or name == "h6"
        or name == "li"
        or name == "ul"
        or name == "ol"
        or name == "dl"
        or name == "dt"
        or name == "dd"
        or name == "blockquote"
        or name == "pre"
        or name == "br"
        or name == "hr"
        or name == "tr"
        or name == "table"
        or name == "thead"
        or name == "tbody"
        or name == "section"
        or name == "article"
        or name == "main"
        or name == "header"
        or name == "footer"
        or name == "aside"
        or name == "nav"
        or name == "figure"
        or name == "figcaption"
        or name == "form"
        or name == "fieldset"
        or name == "address"
        or name == "details"
        or name == "summary"
        or name == "body"
    )


def _is_excluded(name: String) -> Bool:
    """Elements whose text content never reaches the extracted body."""
    return (
        name == "script"
        or name == "style"
        or name == "noscript"
        or name == "template"
        or name == "nav"
    )


def _heading_level(name: String) -> Int:
    """1–6 for h1–h6, else 0."""
    if name.byte_length() != 2:
        return 0
    var bytes = name.as_bytes()
    if bytes[0] != UInt8(ord("h")):
        return 0
    var d = Int(bytes[1]) - ord("0")
    if d >= 1 and d <= 6:
        return d
    return 0


def _ws_to_space(s: String) -> String:
    """Map control whitespace to plain spaces so raw source newlines are
    never mistaken for the block markers this module inserts."""
    var bytes = s.as_bytes()
    var out = List[UInt8](capacity=len(bytes))
    for b in bytes:
        if b == 0x09 or b == 0x0A or b == 0x0D or b == 0x0C:
            out.append(0x20)
        else:
            out.append(b)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _collapse(s: String) -> String:
    """Collapse whitespace runs (including U+00A0) to single spaces and
    trim the ends."""
    var bytes = s.as_bytes()
    var out = String()
    var i = 0
    var n = len(bytes)
    var pending_space = False
    while i < n:
        var b = bytes[i]
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D or b == 0x0C:
            pending_space = True
            i += 1
            continue
        if b == 0xC2 and i + 1 < n and bytes[i + 1] == 0xA0:
            pending_space = True
            i += 2
            continue
        if pending_space and out.byte_length() > 0:
            out += String(" ")
        pending_space = False
        var run_start = i
        while i < n:
            var c = bytes[i]
            if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D or (
                c == 0x0C
            ):
                break
            if c == 0xC2 and i + 1 < n and bytes[i + 1] == 0xA0:
                break
            i += 1
        out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
    return out^


def _normalize_blocks(raw: String) raises -> String:
    """Collapse whitespace within each '\\n'-delimited block and join
    the non-empty blocks with single newlines."""
    var out = String()
    for part in raw.split("\n"):
        var line = _collapse(String(part))
        if line.byte_length() == 0:
            continue
        if out.byte_length() > 0:
            out += String("\n")
        out += line
    return out^


def _attr(attrs: Dict[String, String], key: StaticString) -> String:
    return String(attrs.get(String(key), String()))


def _nearest_open(stack: List[String], name: String) -> Int:
    """Index of the nearest open element with `name`, or -1."""
    for i in range(len(stack) - 1, -1, -1):
        if stack[i] == name:
            return i
    return -1


def extract(var source: String) raises -> Page:
    """Parse an HTML document and extract metadata plus readable text.

    - `title` comes from <title>, falling back to og:title.
    - `meta_description` from <meta name=description> or og:description.
    - `canonical_url` from <link rel=canonical>; `lang` from <html lang>.
    - `text` is block-aware body text: block elements produce newlines,
      whitespace collapses within blocks, and script/style/nav/noscript/
      template content is excluded.
    - `headings` and `links` collect h1–h6 and <a href> from the body.
    """
    var tok = HtmlTokenizer(source^)
    var page = Page()
    var stack = List[String]()
    var excluded = 0
    var head_depth = 0
    var title_depth = 0
    var title_raw = String()
    var og_title = String()
    var body_raw = String()
    var a_active = False
    var a_href = String()
    var a_raw = String()
    var h_level = 0
    var h_raw = String()

    while True:
        var event = tok.next_event()
        if event.kind == EVENT_EOF:
            break

        if event.kind == EVENT_START:
            ref name = event.name
            stack.append(name.copy())
            if name == "html":
                if page.lang.byte_length() == 0:
                    page.lang = _attr(event.attrs, "lang")
            elif name == "head":
                head_depth += 1
            elif name == "title":
                title_depth += 1
            elif name == "meta":
                var meta_name = _attr(event.attrs, "name").lower()
                var meta_prop = _attr(event.attrs, "property").lower()
                var content = _attr(event.attrs, "content")
                if meta_name == "description" or (
                    meta_prop == "og:description"
                ):
                    if page.meta_description.byte_length() == 0:
                        page.meta_description = content^
                elif meta_prop == "og:title":
                    if og_title.byte_length() == 0:
                        og_title = content^
            elif name == "link":
                if _attr(event.attrs, "rel").lower() == "canonical":
                    if page.canonical_url.byte_length() == 0:
                        page.canonical_url = _attr(event.attrs, "href")
            if _is_excluded(name):
                excluded += 1
            if excluded == 0 and head_depth == 0 and title_depth == 0:
                if name == "a":
                    if a_active:
                        # Nested/unclosed <a>: flush the previous link.
                        var prev = _collapse(a_raw)
                        if a_href.byte_length() > 0:
                            page.links.append(Link(a_href.copy(), prev^))
                    a_active = True
                    a_href = _attr(event.attrs, "href")
                    a_raw = String()
                var lvl = _heading_level(name)
                if lvl > 0:
                    if h_level > 0:
                        var prev = _collapse(h_raw)
                        if prev.byte_length() > 0:
                            page.headings.append(Heading(h_level, prev^))
                    h_level = lvl
                    h_raw = String()
                if _is_block(name):
                    body_raw += String("\n")
                elif name == "td" or name == "th":
                    body_raw += String(" ")

        elif event.kind == EVENT_TEXT:
            if excluded > 0:
                continue
            if title_depth > 0:
                title_raw += event.text
                continue
            if head_depth > 0:
                continue
            var t = _ws_to_space(event.text)
            body_raw += t
            if a_active:
                a_raw += t
            if h_level > 0:
                h_raw += t

        elif event.kind == EVENT_END:
            # Liberal recovery: match the nearest open element with this
            # name, implicitly closing anything opened above it. A stray
            # end tag matching nothing is ignored.
            var idx = _nearest_open(stack, event.name)
            if idx == -1:
                continue
            var j = len(stack) - 1
            while j >= idx:
                ref closing = stack[j]
                if closing == "head":
                    if head_depth > 0:
                        head_depth -= 1
                elif closing == "title":
                    if title_depth > 0:
                        title_depth -= 1
                if _is_excluded(closing):
                    excluded -= 1
                if excluded == 0 and head_depth == 0 and title_depth == 0:
                    if closing == "a" and a_active:
                        var text = _collapse(a_raw)
                        if a_href.byte_length() > 0:
                            page.links.append(Link(a_href.copy(), text^))
                        a_active = False
                        a_raw = String()
                    var lvl = _heading_level(closing)
                    if lvl > 0 and h_level > 0:
                        var text = _collapse(h_raw)
                        if text.byte_length() > 0:
                            page.headings.append(Heading(h_level, text^))
                        h_level = 0
                        h_raw = String()
                    if _is_block(closing):
                        body_raw += String("\n")
                    elif closing == "td" or closing == "th":
                        body_raw += String(" ")
                j -= 1
            stack.shrink(idx)

    # Flush anything left open at EOF.
    if a_active and a_href.byte_length() > 0:
        page.links.append(Link(a_href.copy(), _collapse(a_raw)))
    if h_level > 0:
        var text = _collapse(h_raw)
        if text.byte_length() > 0:
            page.headings.append(Heading(h_level, text^))
    page.title = _collapse(title_raw)
    if page.title.byte_length() == 0:
        page.title = _collapse(og_title)
    page.text = _normalize_blocks(body_raw)
    return page^



# --- readability-style main-content scorer --------------------------------


def _is_drop_subtree(name: String) -> Bool:
    """Elements whose entire subtree is boilerplate and never scored."""
    return (
        name == "script"
        or name == "style"
        or name == "noscript"
        or name == "template"
        or name == "iframe"
        or name == "embed"
        or name == "object"
        or name == "applet"
        or name == "canvas"
        or name == "svg"
        or name == "math"
        or name == "form"
        or name == "input"
        or name == "button"
        or name == "select"
        or name == "option"
        or name == "textarea"
        or name == "label"
        or name == "legend"
        or name == "fieldset"
        or name == "output"
        or name == "progress"
        or name == "meter"
        or name == "nav"
        or name == "aside"
        or name == "footer"
        or name == "audio"
        or name == "video"
        or name == "source"
        or name == "track"
        or name == "picture"
        or name == "map"
        or name == "area"
        or name == "frame"
        or name == "frameset"
        or name == "dialog"
        or name == "marquee"
        or name == "menu"
        or name == "rp"
        or name == "rt"
        or name == "rtc"
    )


def _role_is_drop(role: String) -> Bool:
    """ARIA roles whose subtree is chrome, not content."""
    return (
        role == "menu"
        or role == "menubar"
        or role == "complementary"
        or role == "navigation"
        or role == "alert"
        or role == "alertdialog"
        or role == "dialog"
    )


def _is_scored_tag(name: String) -> Bool:
    """Paragraph-like tags that seed content scores (divs handled by the
    div-as-p rule separately)."""
    return (
        name == "p"
        or name == "td"
        or name == "pre"
        or name == "section"
        or name == "h2"
        or name == "h3"
        or name == "h4"
        or name == "h5"
        or name == "h6"
    )


def _tag_adjustment(name: String) -> Float64:
    """Per-tag init bonus/penalty applied when a node first becomes a
    scoring candidate."""
    if name == "div":
        return 5.0
    if name == "pre" or name == "td" or name == "blockquote":
        return 3.0
    if (
        name == "address"
        or name == "ol"
        or name == "ul"
        or name == "dl"
        or name == "dd"
        or name == "dt"
        or name == "li"
        or name == "form"
    ):
        return -3.0
    if (
        name == "h1"
        or name == "h2"
        or name == "h3"
        or name == "h4"
        or name == "h5"
        or name == "h6"
        or name == "th"
    ):
        return -5.0
    return 0.0


def _is_divp_block(name: String) -> Bool:
    """Child tags that disqualify a <div> from the div-as-p rule (a div
    with any of these children is a container, not a paragraph)."""
    return (
        name == "a"
        or name == "blockquote"
        or name == "dl"
        or name == "div"
        or name == "img"
        or name == "ol"
        or name == "p"
        or name == "pre"
        or name == "table"
        or name == "ul"
        or name == "select"
    )


def _has_any(hay: String, needles: List[String]) -> Bool:
    for n in needles:
        if n in hay:
            return True
    return False


def _class_weight(
    class_id: String, pos: List[String], neg: List[String]
) -> Float64:
    """Readability class/id keyword weight: +25 for a positive substring,
    -25 for a negative one (independent, so both can apply)."""
    var w = 0.0
    if _has_any(class_id, pos):
        w += 25.0
    if _has_any(class_id, neg):
        w -= 25.0
    return w


struct NodeRec(Copyable, Movable):
    """Compact per-element record built during the streaming pass."""

    var tag: String
    var class_id: String
    var parent: Int
    var frag_start: Int
    var frag_end: Int
    var text_len: Int
    var comma: Int
    var link_len: Int
    var block_children: Int
    var is_main_region: Bool
    var href_hash: Bool
    var score: Float64
    var initialized: Bool

    def __init__(
        out self,
        var tag: String,
        var class_id: String,
        parent: Int,
        frag_start: Int,
        is_main_region: Bool,
        href_hash: Bool,
    ):
        self.tag = tag^
        self.class_id = class_id^
        self.parent = parent
        self.frag_start = frag_start
        self.frag_end = frag_start
        self.text_len = 0
        self.comma = 0
        self.link_len = 0
        self.block_children = 0
        self.is_main_region = is_main_region
        self.href_hash = href_hash
        self.score = 0.0
        self.initialized = False


@fieldwise_init
struct MainContent(Copyable, Movable):
    """Main-content text plus a confidence flag. `confident` is false for
    thin or low-score output (paywall stubs, empty pages)."""

    var text: String
    var confident: Bool


def _slice_text(frag: List[String], start: Int, end: Int) raises -> String:
    var buf = String()
    var k = start
    while k < end:
        buf += frag[k]
        k += 1
    return _normalize_blocks(buf)


def main_text_confident(var source: String) raises -> MainContent:
    """Readability-style main-content extraction with a confidence flag.

    One streaming pass builds a compact node tree (dropping script/nav/
    aside/footer/form/svg and friends), then paragraph-like nodes seed
    content scores that propagate to ancestors and are discounted by link
    density. An <article>/<main>/[role=main] fast path wins when exactly
    one such region exists with >140 chars of text. `confident` is false
    when the winning text is under 140 chars or scores under 20.
    """
    var tok = HtmlTokenizer(source^)
    var stack = List[String]()
    var node_idx = List[Int]()
    var stack_drop = List[Bool]()
    var open_nodes = List[Int]()
    var nodes = List[NodeRec]()
    var frag = List[String]()
    var dropped = 0
    var head_depth = 0
    var title_depth = 0

    while True:
        var event = tok.next_event()
        if event.kind == EVENT_EOF:
            break

        if event.kind == EVENT_START:
            ref name = event.name
            var caused_drop = False
            var this_node = -1
            if name == "head":
                head_depth += 1
            elif name == "title":
                title_depth += 1
            var role = _attr(event.attrs, "role").lower()
            if _is_drop_subtree(name) or _role_is_drop(role):
                dropped += 1
                caused_drop = True
            elif dropped == 0 and head_depth == 0 and title_depth == 0:
                var parent = -1
                if len(open_nodes) > 0:
                    parent = open_nodes[len(open_nodes) - 1]
                var cls = _attr(event.attrs, "class")
                var idv = _attr(event.attrs, "id")
                var class_id = (cls + String(" ") + idv).lower()
                var is_main = (
                    name == "article" or name == "main" or role == "main"
                )
                var href_hash = False
                if name == "a":
                    href_hash = _attr(event.attrs, "href").startswith("#")
                var fs = len(frag)
                this_node = len(nodes)
                nodes.append(
                    NodeRec(
                        name.copy(), class_id^, parent, fs, is_main, href_hash
                    )
                )
                open_nodes.append(this_node)
                if _is_block(name):
                    frag.append(String("\n"))
                elif name == "td" or name == "th":
                    frag.append(String(" "))
            stack.append(name.copy())
            node_idx.append(this_node)
            stack_drop.append(caused_drop)

        elif event.kind == EVENT_TEXT:
            if dropped > 0 or head_depth > 0 or title_depth > 0:
                continue
            if len(open_nodes) == 0:
                continue
            frag.append(_ws_to_space(event.text))
            var top = open_nodes[len(open_nodes) - 1]
            var ct = _collapse(event.text)
            nodes[top].text_len += ct.byte_length()
            for b in ct.as_bytes():
                if b == UInt8(ord(",")):
                    nodes[top].comma += 1

        elif event.kind == EVENT_END:
            var idx = _nearest_open(stack, event.name)
            if idx == -1:
                continue
            var j = len(stack) - 1
            while j >= idx:
                ref closing = stack[j]
                if closing == "head":
                    if head_depth > 0:
                        head_depth -= 1
                elif closing == "title":
                    if title_depth > 0:
                        title_depth -= 1
                if stack_drop[j]:
                    if dropped > 0:
                        dropped -= 1
                var ni = node_idx[j]
                if ni != -1:
                    if _is_block(closing):
                        frag.append(String("\n"))
                    elif closing == "td" or closing == "th":
                        frag.append(String(" "))
                    nodes[ni].frag_end = len(frag)
                    if closing == "a":
                        var ll = nodes[ni].text_len
                        if nodes[ni].href_hash:
                            ll = Int(0.3 * Float64(ll))
                        nodes[ni].link_len += ll
                    var par = nodes[ni].parent
                    if par != -1:
                        nodes[par].text_len += nodes[ni].text_len
                        nodes[par].comma += nodes[ni].comma
                        nodes[par].link_len += nodes[ni].link_len
                        if _is_divp_block(closing):
                            nodes[par].block_children += 1
                    if len(open_nodes) > 0:
                        _ = open_nodes.pop()
                j -= 1
            stack.shrink(idx)
            node_idx.shrink(idx)
            stack_drop.shrink(idx)

    # Flush anything left open at EOF (tag soup), deepest first.
    var j = len(stack) - 1
    while j >= 0:
        var ni = node_idx[j]
        if ni != -1:
            ref closing = stack[j]
            if _is_block(closing):
                frag.append(String("\n"))
            elif closing == "td" or closing == "th":
                frag.append(String(" "))
            nodes[ni].frag_end = len(frag)
            if closing == "a":
                var ll = nodes[ni].text_len
                if nodes[ni].href_hash:
                    ll = Int(0.3 * Float64(ll))
                nodes[ni].link_len += ll
            var par = nodes[ni].parent
            if par != -1:
                nodes[par].text_len += nodes[ni].text_len
                nodes[par].comma += nodes[ni].comma
                nodes[par].link_len += nodes[ni].link_len
                if _is_divp_block(closing):
                    nodes[par].block_children += 1
        j -= 1

    # --- fast path: exactly one <article>/<main>/[role=main] region -------
    var main_count = 0
    var main_i = -1
    for i in range(len(nodes)):
        if nodes[i].is_main_region:
            main_count += 1
            main_i = i
    if main_count == 1 and nodes[main_i].text_len > 140:
        var text = _slice_text(
            frag, nodes[main_i].frag_start, nodes[main_i].frag_end
        )
        return MainContent(text^, True)

    # --- full scoring -----------------------------------------------------
    var pos = [
        String("article"),
        String("body"),
        String("content"),
        String("entry"),
        String("hentry"),
        String("h-entry"),
        String("main"),
        String("page"),
        String("pagination"),
        String("post"),
        String("text"),
        String("blog"),
        String("story"),
    ]
    var neg = [
        String("-ad-"),
        String("hidden"),
        String("banner"),
        String("combx"),
        String("comment"),
        String("com-"),
        String("contact"),
        String("footer"),
        String("gdpr"),
        String("masthead"),
        String("media"),
        String("meta"),
        String("outbrain"),
        String("promo"),
        String("related"),
        String("scroll"),
        String("share"),
        String("shoutbox"),
        String("sidebar"),
        String("skyscraper"),
        String("sponsor"),
        String("shopping"),
        String("tags"),
        String("widget"),
    ]

    # Pre-initialize semantic regions so a short but real <article> still
    # beats sidebar noise.
    for i in range(len(nodes)):
        if nodes[i].is_main_region:
            nodes[i].initialized = True
            nodes[i].score = (
                _tag_adjustment(nodes[i].tag)
                + _class_weight(nodes[i].class_id, pos, neg)
                + 25.0
            )

    for i in range(len(nodes)):
        var tag = nodes[i].tag
        var is_para = _is_scored_tag(tag) or (
            tag == "div" and nodes[i].block_children == 0
        )
        if not is_para:
            continue
        if nodes[i].text_len < 25:
            continue
        var lp = nodes[i].text_len // 100
        if lp > 3:
            lp = 3
        var base = 1.0 + Float64(nodes[i].comma) + Float64(lp)
        var anc = nodes[i].parent
        var level = 0
        while anc != -1 and level < 5:
            if not nodes[anc].initialized:
                nodes[anc].initialized = True
                nodes[anc].score = _tag_adjustment(
                    nodes[anc].tag
                ) + _class_weight(nodes[anc].class_id, pos, neg)
            var divider = 1.0
            if level == 1:
                divider = 2.0
            elif level >= 2:
                divider = Float64(level * 3)
            nodes[anc].score += base / divider
            anc = nodes[anc].parent
            level += 1

    var best = -1.0e18
    var best_i = -1
    for i in range(len(nodes)):
        if not nodes[i].initialized:
            continue
        var density = 0.0
        if nodes[i].text_len > 0:
            density = Float64(nodes[i].link_len) / Float64(nodes[i].text_len)
            if density > 1.0:
                density = 1.0
        var fin = nodes[i].score * (1.0 - density)
        if fin > best:
            best = fin
            best_i = i

    if best_i == -1:
        # No scored candidate — return the whole filtered body, unconfident.
        var text = _slice_text(frag, 0, len(frag))
        return MainContent(text^, False)

    var text = _slice_text(
        frag, nodes[best_i].frag_start, nodes[best_i].frag_end
    )
    var confident = text.byte_length() >= 140 and best >= 20.0
    return MainContent(text^, confident)


def main_text(var source: String) raises -> String:
    """Best-effort main-content text (see `main_text_confident`). Returns
    just the text for API compatibility."""
    var mc = main_text_confident(source^)
    return mc.text.copy()
