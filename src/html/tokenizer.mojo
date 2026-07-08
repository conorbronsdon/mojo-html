"""Liberal HTML tokenizer.

Emits a flat stream of events (start element, end element, text) from an
HTML document held in memory. Adapted from mojo-feed's XML pull parser
with HTML semantics: tag and attribute names are lowercased, void
elements emit synthetic end events, raw-text elements (script, style,
textarea, title) are consumed literally until their matching close tag,
unquoted attribute values are accepted, and the named-entity table
covers the common HTML entities beyond XML's five.

Real-world HTML is tag soup: the tokenizer never raises on malformed
markup in its default liberal mode. Structural recovery (unclosed <p>,
<li>, crossed tags) is the mapping layer's job — see extract.mojo.
"""

from html.errors import parse_error

comptime EVENT_START = 0
comptime EVENT_END = 1
comptime EVENT_TEXT = 2
comptime EVENT_EOF = 3

comptime _LT = UInt8(ord("<"))
comptime _GT = UInt8(ord(">"))
comptime _AMP = UInt8(ord("&"))
comptime _SLASH = UInt8(ord("/"))
comptime _BANG = UInt8(ord("!"))
comptime _QUESTION = UInt8(ord("?"))
comptime _EQUALS = UInt8(ord("="))
comptime _SQUOTE = UInt8(ord("'"))
comptime _DQUOTE = UInt8(ord('"'))
comptime _SEMI = UInt8(ord(";"))
comptime _HASH = UInt8(ord("#"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))


def _is_space(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D or b == 0x0C


def _is_alpha(b: UInt8) -> Bool:
    return (b >= UInt8(ord("a")) and b <= UInt8(ord("z"))) or (
        b >= UInt8(ord("A")) and b <= UInt8(ord("Z"))
    )


def _to_lower(b: UInt8) -> UInt8:
    if b >= UInt8(ord("A")) and b <= UInt8(ord("Z")):
        return b + 32
    return b


def is_void_element(name: String) -> Bool:
    """True for HTML void elements, which never take an end tag."""
    return (
        name == "area"
        or name == "base"
        or name == "br"
        or name == "col"
        or name == "embed"
        or name == "hr"
        or name == "img"
        or name == "input"
        or name == "link"
        or name == "meta"
        or name == "param"
        or name == "source"
        or name == "track"
        or name == "wbr"
    )


def _is_rawtext_element(name: String) -> Bool:
    """Elements whose content is consumed literally until the matching
    case-insensitive close tag."""
    return (
        name == "script"
        or name == "style"
        or name == "textarea"
        or name == "title"
    )


def _rawtext_decodes_entities(name: String) -> Bool:
    """Escapable raw text (title, textarea) gets entity decoding;
    script and style stay byte-literal."""
    return name == "title" or name == "textarea"


def _append_codepoint(mut out: String, cp_in: Int):
    """UTF-8 encode a Unicode scalar value and append it to `out`.

    Out-of-range and surrogate codepoints become U+FFFD (replacement
    character) rather than producing invalid UTF-8.
    """
    var cp = cp_in
    if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
        cp = 0xFFFD
    var buf = List[UInt8]()
    if cp < 0x80:
        buf.append(UInt8(cp))
    elif cp < 0x800:
        buf.append(UInt8(0xC0 | (cp >> 6)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        buf.append(UInt8(0xE0 | (cp >> 12)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (cp >> 18)))
        buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    out += String(StringSlice(unsafe_from_utf8=Span(buf)))


def _cp1252_codepoint(b: UInt8) -> Int:
    """Map a Windows-1252 byte to its Unicode codepoint.

    Identity for everything except 0x80–0x9F, where Windows-1252 differs
    from Latin-1. Treating declared Latin-1 as CP1252 matches browser
    behavior (the C1 range is unused control codes in real Latin-1 text).
    """
    var c = Int(b)
    if c < 0x80 or c > 0x9F:
        return c
    var table: List[Int] = [
        0x20AC,
        0x81,
        0x201A,
        0x0192,
        0x201E,
        0x2026,
        0x2020,
        0x2021,
        0x02C6,
        0x2030,
        0x0160,
        0x2039,
        0x0152,
        0x8D,
        0x017D,
        0x8F,
        0x90,
        0x2018,
        0x2019,
        0x201C,
        0x201D,
        0x2022,
        0x2013,
        0x2014,
        0x02DC,
        0x2122,
        0x0161,
        0x203A,
        0x0153,
        0x9D,
        0x017E,
        0x0178,
    ]
    return table[c - 0x80]


def _named_entity_cp(name: String) -> Int:
    """Codepoint for a named HTML entity, or -1 if unknown.

    Covers XML's five plus the entities that actually show up in
    article prose. Unknown names pass through verbatim (liberal mode).
    """
    if name == "amp":
        return 38
    if name == "lt":
        return 60
    if name == "gt":
        return 62
    if name == "quot":
        return 34
    if name == "apos":
        return 39
    if name == "nbsp":
        return 0xA0
    if name == "mdash":
        return 0x2014
    if name == "ndash":
        return 0x2013
    if name == "hellip":
        return 0x2026
    if name == "rsquo":
        return 0x2019
    if name == "lsquo":
        return 0x2018
    if name == "rdquo":
        return 0x201D
    if name == "ldquo":
        return 0x201C
    if name == "copy":
        return 0xA9
    if name == "reg":
        return 0xAE
    if name == "trade":
        return 0x2122
    if name == "times":
        return 0xD7
    if name == "laquo":
        return 0xAB
    if name == "raquo":
        return 0xBB
    if name == "middot":
        return 0xB7
    if name == "bull":
        return 0x2022
    if name == "dagger":
        return 0x2020
    if name == "sect":
        return 0xA7
    if name == "para":
        return 0xB6
    if name == "deg":
        return 0xB0
    if name == "plusmn":
        return 0xB1
    if name == "frac12":
        return 0xBD
    if name == "eacute":
        return 0xE9
    if name == "egrave":
        return 0xE8
    if name == "agrave":
        return 0xE0
    if name == "ccedil":
        return 0xE7
    if name == "ouml":
        return 0xF6
    if name == "uuml":
        return 0xFC
    if name == "auml":
        return 0xE4
    if name == "szlig":
        return 0xDF
    if name == "ntilde":
        return 0xF1
    if name == "aacute":
        return 0xE1
    if name == "iacute":
        return 0xED
    if name == "oacute":
        return 0xF3
    if name == "uacute":
        return 0xFA
    return -1


def _transcode_latin(bytes: Span[UInt8, _]) -> String:
    """Re-encode Windows-1252/Latin-1 bytes as UTF-8.

    Takes raw bytes directly (not a String) because the input is by
    definition not valid UTF-8 — wrapping it in a String first would
    smuggle invalid bytes past `unsafe_from_utf8`.
    """
    var out = String()
    var i = 0
    while i < len(bytes):
        if bytes[i] < 0x80:
            var run_start = i
            while i < len(bytes) and bytes[i] < 0x80:
                i += 1
            out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
        else:
            _append_codepoint(out, _cp1252_codepoint(bytes[i]))
            i += 1
    return out^


def _declared_encoding(head: String) -> String:
    """Lowercased charset declared in the document head, or "".

    Sniffs `charset=` anywhere in the head slice, which covers
    `<meta charset="…">`, `<meta http-equiv="Content-Type"
    content="text/html; charset=…">`, and XML declarations alike.
    """
    var lowered = head.lower()
    var idx = lowered.find("charset")
    if idx == -1:
        return String()
    var bytes = lowered.as_bytes()
    var i = idx + 7
    var n = len(bytes)
    while i < n and (_is_space(bytes[i]) or bytes[i] == _EQUALS):
        i += 1
    if i < n and (bytes[i] == _SQUOTE or bytes[i] == _DQUOTE):
        i += 1
    var start = i
    while i < n:
        var b = bytes[i]
        if (
            _is_space(b)
            or b == _SQUOTE
            or b == _DQUOTE
            or b == _GT
            or b == _SLASH
            or b == _SEMI
        ):
            break
        i += 1
    return String(StringSlice(unsafe_from_utf8=bytes[start:i]))


def _transcode_utf16(data: Span[UInt8, _], little_endian: Bool) -> String:
    """Decode UTF-16 (after the BOM) to UTF-8, with U+FFFD recovery."""
    var out = String()
    var i = 2  # skip BOM
    while i + 1 < len(data):
        var unit: Int
        if little_endian:
            unit = Int(data[i]) | (Int(data[i + 1]) << 8)
        else:
            unit = (Int(data[i]) << 8) | Int(data[i + 1])
        i += 2
        if unit >= 0xD800 and unit <= 0xDBFF:
            # High surrogate: needs a following low surrogate.
            if i + 1 < len(data):
                var low: Int
                if little_endian:
                    low = Int(data[i]) | (Int(data[i + 1]) << 8)
                else:
                    low = (Int(data[i]) << 8) | Int(data[i + 1])
                if low >= 0xDC00 and low <= 0xDFFF:
                    i += 2
                    var cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    _append_codepoint(out, cp)
                    continue
            _append_codepoint(out, 0xFFFD)
        elif unit >= 0xDC00 and unit <= 0xDFFF:
            _append_codepoint(out, 0xFFFD)  # unpaired low surrogate
        else:
            _append_codepoint(out, unit)
    if i < len(data):
        _append_codepoint(out, 0xFFFD)  # trailing odd byte
    return out^


def _utf8_lossy(data: Span[UInt8, _]) -> String:
    """Build a String from bytes, replacing invalid UTF-8 with U+FFFD."""
    var out = String()
    var i = 0
    var n = len(data)
    while i < n:
        var b = data[i]
        if b < 0x80:
            var run_start = i
            while i < n and data[i] < 0x80:
                i += 1
            out += String(StringSlice(unsafe_from_utf8=data[run_start:i]))
            continue
        var seq_len = 0
        var cp = 0
        if b >= 0xC2 and b <= 0xDF:
            seq_len = 2
            cp = Int(b) & 0x1F
        elif b >= 0xE0 and b <= 0xEF:
            seq_len = 3
            cp = Int(b) & 0x0F
        elif b >= 0xF0 and b <= 0xF4:
            seq_len = 4
            cp = Int(b) & 0x07
        if seq_len == 0 or i + seq_len > n:
            _append_codepoint(out, 0xFFFD)
            i += 1
            continue
        var ok = True
        for k in range(1, seq_len):
            var c = data[i + k]
            if c < 0x80 or c > 0xBF:
                ok = False
                break
            cp = (cp << 6) | (Int(c) & 0x3F)
        # Reject overlong encodings: a codepoint must use the shortest form.
        # E.g. E0 80 80 decodes to U+0000 but is an overlong 3-byte form;
        # accepting it would round the raw bytes back into the String and
        # poison every downstream operation on it.
        var min_cp = 0x80
        if seq_len == 3:
            min_cp = 0x800
        elif seq_len == 4:
            min_cp = 0x10000
        if (
            not ok
            or cp < min_cp
            or cp > 0x10FFFF
            or (cp >= 0xD800 and cp <= 0xDFFF)
        ):
            _append_codepoint(out, 0xFFFD)
            i += 1
            continue
        out += String(StringSlice(unsafe_from_utf8=data[i : i + seq_len]))
        i += seq_len
    return out^


def normalize_encoding_bytes(data: Span[UInt8, _]) raises -> String:
    """Produce a valid UTF-8 String from raw page bytes.

    Handles UTF-16 (LE/BE, by BOM), UTF-8 BOM stripping, declared
    Latin-1/CP1252 transcoding (from `<meta charset>` or an XML
    declaration), and lossy U+FFFD recovery for invalid UTF-8.
    Unknown declared encodings fall back to lossy UTF-8 — a wrong
    guess degrades some characters, never the whole parse.
    """
    if len(data) >= 2:
        if data[0] == 0xFF and data[1] == 0xFE:
            return _transcode_utf16(data, little_endian=True)
        if data[0] == 0xFE and data[1] == 0xFF:
            return _transcode_utf16(data, little_endian=False)
    var body = data
    if (
        len(data) >= 3
        and data[0] == 0xEF
        and data[1] == 0xBB
        and (data[2] == 0xBF)
    ):
        body = data[3:]
    # The charset declaration is ASCII, so a lossy view is safe to sniff.
    var head_len = len(body)
    if head_len > 1024:
        head_len = 1024
    var head = _utf8_lossy(body[0:head_len])
    var enc = _declared_encoding(head)
    if (
        enc == "iso-8859-1"
        or enc == "latin-1"
        or enc == "latin1"
        or enc == "windows-1252"
        or enc == "cp1252"
    ):
        return _transcode_latin(body)
    return _utf8_lossy(body)


def normalize_encoding(var source: String) raises -> String:
    """String-input variant of `normalize_encoding_bytes`."""
    return normalize_encoding_bytes(source.as_bytes())


@fieldwise_init
struct HtmlEvent(Copyable, Movable, Writable):
    """One parse event. `attrs` is populated only for EVENT_START."""

    var kind: Int
    var name: String
    var text: String
    var attrs: Dict[String, String]

    @staticmethod
    def start(var name: String, var attrs: Dict[String, String]) -> HtmlEvent:
        return HtmlEvent(EVENT_START, name^, String(), attrs^)

    @staticmethod
    def end(var name: String) -> HtmlEvent:
        return HtmlEvent(EVENT_END, name^, String(), Dict[String, String]())

    @staticmethod
    def text_event(var text: String) -> HtmlEvent:
        return HtmlEvent(EVENT_TEXT, String(), text^, Dict[String, String]())

    @staticmethod
    def eof() -> HtmlEvent:
        return HtmlEvent(EVENT_EOF, String(), String(), Dict[String, String]())

    def write_to(self, mut writer: Some[Writer]):
        if self.kind == EVENT_START:
            writer.write("Start(", self.name, ")")
        elif self.kind == EVENT_END:
            writer.write("End(", self.name, ")")
        elif self.kind == EVENT_TEXT:
            writer.write("Text(", self.text, ")")
        else:
            writer.write("Eof")


struct HtmlTokenizer(Copyable, Movable):
    """Pull events with `next_event()` until it returns EVENT_EOF.

    Void elements and self-closing tags emit a synthetic end event
    immediately after their start event, so consumers always see
    balanced start/end pairs for them. Raw-text elements emit their
    content as a single text event followed by a synthetic end.

    With `strict=True` the tokenizer reports well-formedness problems —
    mismatched or stray end tags, elements left open at EOF, malformed
    or unknown entities — as errors with a line/column location and a
    snippet of the offending line instead of recovering liberally.
    Useful for linting HTML you produce; leave it off for pages you
    merely consume.
    """

    var src: String
    var pos: Int
    var strict: Bool
    var _pending_end: String
    var _has_pending_end: Bool
    var _rawtext: String
    var _open: List[String]
    # Byte offset of each open element's start tag, parallel to `_open`,
    # so an unclosed-element error can point at the construct start
    # rather than the (useless) EOF position.
    var _open_pos: List[Int]

    def __init__(out self, var source: String, *, strict: Bool = False) raises:
        self.src = normalize_encoding(source^)
        self.pos = 0
        self.strict = strict
        self._pending_end = String()
        self._has_pending_end = False
        self._rawtext = String()
        self._open = List[String]()
        self._open_pos = List[Int]()

    def _strict_error(self, msg: String, p: Int) -> Error:
        """Strict-mode error locating `msg` at byte offset `p`.

        Position and snippet come from `html.errors.parse_error`, so the
        message reads `mojo-html [strict]: <msg> at line <L>, column <C>:
        '<snippet>'`. Computed lazily (only on error paths), so the happy
        path pays nothing for location tracking.
        """
        return parse_error("mojo-html [strict]: " + msg, self.src.as_bytes(), p)

    def _len(self) -> Int:
        return self.src.byte_length()

    def _at(self, i: Int) -> UInt8:
        return self.src.as_bytes()[i]

    def _slice_to_string(self, start: Int, end: Int) -> String:
        return String(
            StringSlice(unsafe_from_utf8=self.src.as_bytes()[start:end])
        )

    def _starts_with(self, i: Int, literal: StaticString) -> Bool:
        var lit_bytes = literal.as_bytes()
        if i + len(lit_bytes) > self._len():
            return False
        for k in range(len(lit_bytes)):
            if self._at(i + k) != lit_bytes[k]:
                return False
        return True

    def _find(self, start: Int, literal: StaticString) -> Int:
        """Byte offset of `literal` at or after `start`, or -1."""
        var i = start
        while i < self._len():
            if self._starts_with(i, literal):
                return i
            i += 1
        return -1

    def _skip_space(mut self):
        while self.pos < self._len() and _is_space(self._at(self.pos)):
            self.pos += 1

    def _tag_open_at(self, i: Int) -> Bool:
        """True when the '<' at byte `i` actually begins markup.

        A '<' followed by anything other than a name, '/', '!', or '?'
        is literal text in HTML (e.g. "a < b").
        """
        if i + 1 >= self._len():
            return False
        var b = self._at(i + 1)
        return _is_alpha(b) or b == _SLASH or b == _BANG or b == _QUESTION

    def _decode_entities(self, var raw: String, base: Int) raises -> String:
        # `base` is the byte offset of `raw`'s first byte within
        # `self.src` (every caller passes a direct slice of the source),
        # so strict-mode entity errors can point at the offending '&'.
        # Zero-copy fast path: most text and attribute values contain no
        # entities at all — hand the string back untouched.
        var has_amp = False
        for b in raw.as_bytes():
            if b == _AMP:
                has_amp = True
                break
        if not has_amp:
            return raw^
        var bytes = raw.as_bytes()
        var out = String()
        var i = 0
        while i < len(bytes):
            var b = bytes[i]
            if b != _AMP:
                # Fast path: copy the contiguous run without entities.
                var run_start = i
                while i < len(bytes) and bytes[i] != _AMP:
                    i += 1
                out += String(StringSlice(unsafe_from_utf8=bytes[run_start:i]))
                continue
            # Find the terminating ';' within a sane distance.
            var semi = -1
            var j = i + 1
            while j < len(bytes) and j < i + 12:
                if bytes[j] == _SEMI:
                    semi = j
                    break
                j += 1
            if semi == -1:
                if self.strict:
                    raise self._strict_error(
                        "bare '&' without a terminated entity", base + i
                    )
                # Malformed bare '&' — pass it through (liberal parsing).
                out += String(StringSlice(unsafe_from_utf8=bytes[i : i + 1]))
                i += 1
                continue
            var entity = self._entity_body(raw, i + 1, semi, base + i)
            out += entity
            i = semi + 1
        return out^

    def _entity_body(
        self, raw: String, start: Int, end: Int, amp_pos: Int
    ) raises -> String:
        # `amp_pos` is the byte offset of the entity's '&' in `self.src`.
        var bytes = raw.as_bytes()
        var out = String()
        if start < end and bytes[start] == _HASH:
            # Numeric character reference: &#38; or &#x26;
            var cp = 0
            var k = start + 1
            var is_hex = k < end and (
                bytes[k] == UInt8(ord("x")) or bytes[k] == UInt8(ord("X"))
            )
            if is_hex:
                k += 1
            # Malformed references pass through verbatim (liberal parsing)
            # rather than failing the whole document.
            var valid = k < end
            while k < end:
                var d = Int(bytes[k])
                if is_hex:
                    if d >= ord("0") and d <= ord("9"):
                        cp = cp * 16 + (d - ord("0"))
                    elif d >= ord("a") and d <= ord("f"):
                        cp = cp * 16 + (d - ord("a") + 10)
                    elif d >= ord("A") and d <= ord("F"):
                        cp = cp * 16 + (d - ord("A") + 10)
                    else:
                        valid = False
                        break
                else:
                    if d >= ord("0") and d <= ord("9"):
                        cp = cp * 10 + (d - ord("0"))
                    else:
                        valid = False
                        break
                k += 1
            if not valid:
                if self.strict:
                    raise self._strict_error(
                        "malformed numeric character reference", amp_pos
                    )
                out += String("&")
                out += String(StringSlice(unsafe_from_utf8=bytes[start:end]))
                out += String(";")
                return out^
            # HTML quirk: numeric references in the C1 control range are
            # near-universally Windows-1252 bytes (&#147; for a curly
            # quote). Remap like browsers do.
            if cp >= 0x80 and cp <= 0x9F:
                cp = _cp1252_codepoint(UInt8(cp))
            _append_codepoint(out, cp)
            return out^
        var name = String(StringSlice(unsafe_from_utf8=bytes[start:end]))
        var cp = _named_entity_cp(name)
        if cp >= 0:
            _append_codepoint(out, cp)
            return out^
        # Unknown named entity — preserve it verbatim (liberal parsing).
        if self.strict:
            raise self._strict_error("unknown entity &" + name + ";", amp_pos)
        return String("&") + name + String(";")

    def _read_name(mut self) -> String:
        """Read a tag or attribute name, lowercased (HTML names are
        case-insensitive)."""
        var start = self.pos
        while self.pos < self._len():
            var b = self._at(self.pos)
            if _is_space(b) or b == _GT or b == _SLASH or b == _EQUALS:
                break
            self.pos += 1
        return self._slice_to_string(start, self.pos).lower()

    def _read_attrs(mut self) raises -> Dict[String, String]:
        var attrs = Dict[String, String]()
        while True:
            self._skip_space()
            if self.pos >= self._len():
                return attrs^  # truncated tag — take what we have
            var b = self._at(self.pos)
            if b == _GT:
                return attrs^
            if b == _SLASH:
                # '/>' ends the tag; a stray '/' inside a tag is noise.
                if self.pos + 1 < self._len() and (
                    self._at(self.pos + 1) == _GT
                ):
                    return attrs^
                self.pos += 1
                continue
            var name = self._read_name()
            if name.byte_length() == 0:
                self.pos += 1  # junk byte inside the tag — skip it
                continue
            self._skip_space()
            var raw = String()
            var raw_base = 0
            var has_value = False
            if self.pos < self._len() and self._at(self.pos) == _EQUALS:
                has_value = True
                self.pos += 1
                self._skip_space()
                if self.pos < self._len():
                    var quote = self._at(self.pos)
                    if quote == _SQUOTE or quote == _DQUOTE:
                        self.pos += 1
                        var vstart = self.pos
                        while self.pos < self._len() and (
                            self._at(self.pos) != quote
                        ):
                            self.pos += 1
                        raw = self._slice_to_string(vstart, self.pos)
                        raw_base = vstart
                        if self.pos < self._len():
                            self.pos += 1  # closing quote
                    else:
                        # Unquoted value: runs to whitespace or '>'.
                        var vstart = self.pos
                        while self.pos < self._len():
                            var c = self._at(self.pos)
                            if _is_space(c) or c == _GT:
                                break
                            self.pos += 1
                        raw = self._slice_to_string(vstart, self.pos)
                        raw_base = vstart
            # First occurrence wins for duplicate attributes (HTML rule).
            if name not in attrs:
                if has_value:
                    attrs[name] = self._decode_entities(raw^, raw_base)
                else:
                    attrs[name] = String()

    def _scan_rawtext(mut self) raises -> HtmlEvent:
        """Consume literal content up to the matching close tag of the
        pending raw-text element, emitting it as one text event."""
        var name = self._rawtext.copy()
        self._rawtext = String()
        var name_bytes = name.as_bytes()
        var n = self._len()
        var start = self.pos
        var close = -1
        var i = start
        while i + 1 < n:
            if self._at(i) == _LT and self._at(i + 1) == _SLASH:
                var matched = True
                for k in range(len(name_bytes)):
                    var j = i + 2 + k
                    if j >= n or _to_lower(self._at(j)) != name_bytes[k]:
                        matched = False
                        break
                if matched:
                    var after = i + 2 + len(name_bytes)
                    if after >= n:
                        close = i
                        break
                    var c = self._at(after)
                    if _is_space(c) or c == _GT or c == _SLASH:
                        close = i
                        break
            i += 1
        var text: String
        if close == -1:
            # Unterminated raw-text element — take the rest (liberal).
            text = self._slice_to_string(start, n)
            self.pos = n
        else:
            text = self._slice_to_string(start, close)
            var p = close + 2 + len(name_bytes)
            while p < n and self._at(p) != _GT:
                p += 1
            if p < n:
                self.pos = p + 1
            else:
                self.pos = n
        if _rawtext_decodes_entities(name):
            text = self._decode_entities(text^, start)
        if text.byte_length() == 0:
            return HtmlEvent.end(name^)
        self._pending_end = name^
        self._has_pending_end = True
        return HtmlEvent.text_event(text^)

    def next_event(mut self) raises -> HtmlEvent:
        if self._has_pending_end:
            self._has_pending_end = False
            return HtmlEvent.end(self._pending_end.copy())
        if self._rawtext.byte_length() > 0:
            return self._scan_rawtext()
        while True:
            if self.pos >= self._len():
                if self.strict and len(self._open) > 0:
                    # Point at the unclosed start tag, not the EOF.
                    raise self._strict_error(
                        "unclosed element <"
                        + self._open[len(self._open) - 1]
                        + "> at end of input",
                        self._open_pos[len(self._open_pos) - 1],
                    )
                return HtmlEvent.eof()
            if self._at(self.pos) != _LT or not self._tag_open_at(self.pos):
                # Text run up to the next real tag; a lone '<' is text.
                var start = self.pos
                self.pos += 1
                while self.pos < self._len():
                    if self._at(self.pos) == _LT and (
                        self._tag_open_at(self.pos)
                    ):
                        break
                    self.pos += 1
                var raw = self._slice_to_string(start, self.pos)
                return HtmlEvent.text_event(self._decode_entities(raw^, start))
            # self.pos is at '<'. Dispatch on the next byte first so the
            # overwhelmingly common plain tags skip the literal probes.
            var next_b = self._at(self.pos + 1)
            if next_b == _BANG:
                if self._starts_with(self.pos, "<!--"):
                    var close = self._find(self.pos + 4, "-->")
                    if close == -1:
                        if self.strict:
                            raise self._strict_error(
                                "unterminated comment", self.pos
                            )
                        self.pos = self._len()
                    else:
                        self.pos = close + 3
                    continue
                if self._starts_with(self.pos, "<![CDATA["):
                    var start = self.pos + 9
                    var close = self._find(start, "]]>")
                    if close == -1:
                        if self.strict:
                            raise self._strict_error(
                                "unterminated CDATA section", self.pos
                            )
                        close = self._len()
                        self.pos = close
                    else:
                        self.pos = close + 3
                    # CDATA content is literal — no entity decoding.
                    return HtmlEvent.text_event(
                        self._slice_to_string(start, close)
                    )
                # DOCTYPE and friends; tolerate an internal subset [...].
                self.pos += 2
                var depth = 0
                while self.pos < self._len():
                    var b = self._at(self.pos)
                    if b == _LBRACKET:
                        depth += 1
                    elif b == _RBRACKET:
                        depth -= 1
                    elif b == _GT and depth <= 0:
                        self.pos += 1
                        break
                    self.pos += 1
                continue
            if next_b == _QUESTION:
                # Processing instructions are bogus comments in HTML:
                # they end at the first '>' (not '?>').
                var close = self._find(self.pos + 2, ">")
                if close == -1:
                    self.pos = self._len()
                else:
                    self.pos = close + 1
                continue
            if next_b == _SLASH:
                var tag_start = self.pos
                self.pos += 2
                var name = self._read_name()
                # Anything else in the end tag (attributes, spaces,
                # stray junk) is discarded up to the closing '>'.
                while self.pos < self._len() and self._at(self.pos) != _GT:
                    self.pos += 1
                if self.pos < self._len():
                    self.pos += 1
                if name.byte_length() == 0:
                    continue  # "</>" or bogus — skip
                if self.strict:
                    if len(self._open) == 0:
                        raise self._strict_error(
                            "stray end tag </" + name + ">", tag_start
                        )
                    var expected = self._open[len(self._open) - 1].copy()
                    if expected != name:
                        raise self._strict_error(
                            "mismatched end tag </"
                            + name
                            + ">, expected </"
                            + expected
                            + ">",
                            tag_start,
                        )
                    _ = self._open.pop()
                    _ = self._open_pos.pop()
                return HtmlEvent.end(name^)
            # Start tag.
            var start_tag_pos = self.pos
            self.pos += 1
            var name = self._read_name()
            var attrs = self._read_attrs()
            var self_closing = False
            if self.pos < self._len() and self._at(self.pos) == _SLASH:
                self_closing = True
                self.pos += 1
                self._skip_space()
            if self.pos < self._len() and self._at(self.pos) == _GT:
                self.pos += 1
            else:
                # Truncated tag at EOF — emit what we saw (liberal).
                self.pos = self._len()
            if self_closing or is_void_element(name):
                self._pending_end = name.copy()
                self._has_pending_end = True
            elif _is_rawtext_element(name):
                self._rawtext = name.copy()
            elif self.strict:
                self._open.append(name.copy())
                self._open_pos.append(start_tag_pos)
            return HtmlEvent.start(name^, attrs^)
