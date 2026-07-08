from std.testing import assert_equal, assert_true, assert_raises, TestSuite

from html.tokenizer import (
    HtmlTokenizer,
    HtmlEvent,
    is_void_element,
    normalize_encoding_bytes,
    EVENT_START,
    EVENT_END,
    EVENT_TEXT,
    EVENT_EOF,
)


def _events(var source: String) raises -> List[HtmlEvent]:
    var tok = HtmlTokenizer(source^)
    var out = List[HtmlEvent]()
    while True:
        var event = tok.next_event()
        if event.kind == EVENT_EOF:
            break
        out.append(event^)
    return out^


def test_simple_element() raises:
    var events = _events("<p>hello</p>")
    assert_equal(len(events), 3)
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].name, "p")
    assert_equal(events[1].kind, EVENT_TEXT)
    assert_equal(events[1].text, "hello")
    assert_equal(events[2].kind, EVENT_END)
    assert_equal(events[2].name, "p")


def test_names_lowercased() raises:
    var events = _events('<DIV Class="Box">x</DIV>')
    assert_equal(events[0].name, "div")
    assert_equal(events[0].attrs["class"], "Box")  # values keep case
    assert_equal(events[2].name, "div")


def test_void_element_synthetic_end() raises:
    var events = _events("<p>a<br>b</p>")
    assert_equal(len(events), 6)
    assert_equal(events[2].kind, EVENT_START)
    assert_equal(events[2].name, "br")
    assert_equal(events[3].kind, EVENT_END)
    assert_equal(events[3].name, "br")
    assert_equal(events[4].text, "b")


def test_void_img_with_attrs() raises:
    var events = _events('<img src="x.png" alt="pic">')
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[0].attrs["src"], "x.png")
    assert_equal(events[1].kind, EVENT_END)
    assert_equal(events[1].name, "img")


def test_self_closing_slash() raises:
    var events = _events("<br/>")
    assert_equal(events[0].kind, EVENT_START)
    assert_equal(events[1].kind, EVENT_END)


def test_unquoted_attribute_value() raises:
    var events = _events("<a href=foo>x</a>")
    assert_equal(events[0].attrs["href"], "foo")


def test_unquoted_values_paths_and_flags() raises:
    var events = _events("<input type=checkbox value=/a/b checked>")
    assert_equal(events[0].attrs["type"], "checkbox")
    assert_equal(events[0].attrs["value"], "/a/b")
    assert_equal(events[0].attrs["checked"], "")
    # input is void: synthetic end follows.
    assert_equal(events[1].kind, EVENT_END)


def test_duplicate_attribute_first_wins() raises:
    var events = _events('<p class="a" class="b">x</p>')
    assert_equal(events[0].attrs["class"], "a")


def test_script_rawtext_ignores_embedded_end_tags() raises:
    var source: String = "<script>a = '</div>' + 1 < 2;</script><p>x</p>"
    var events = _events(source^)
    assert_equal(events[0].name, "script")
    assert_equal(events[1].kind, EVENT_TEXT)
    assert_equal(events[1].text, "a = '</div>' + 1 < 2;")
    assert_equal(events[2].kind, EVENT_END)
    assert_equal(events[2].name, "script")
    assert_equal(events[3].name, "p")


def test_style_rawtext() raises:
    var events = _events("<style>a>b{color:red}&amp;</style>")
    assert_equal(events[1].text, "a>b{color:red}&amp;")  # no decoding


def test_title_entity_decoded() raises:
    var events = _events("<title>A &amp; B &mdash; C</title>")
    assert_equal(events[0].name, "title")
    assert_equal(events[1].text, "A & B — C")
    assert_equal(events[2].kind, EVENT_END)


def test_textarea_rawtext() raises:
    var events = _events("<textarea><b>not bold</b></textarea>")
    assert_equal(events[1].text, "<b>not bold</b>")


def test_rawtext_close_case_insensitive() raises:
    var events = _events("<SCRIPT>x</ScRiPt ><p>y</p>")
    assert_equal(events[0].name, "script")
    assert_equal(events[1].text, "x")
    assert_equal(events[2].kind, EVENT_END)
    assert_equal(events[3].name, "p")


def test_unterminated_script_liberal() raises:
    var events = _events("<script>alert(1)")
    assert_equal(events[0].name, "script")
    assert_equal(events[1].text, "alert(1)")
    assert_equal(events[2].kind, EVENT_END)  # synthetic end at EOF


def test_named_entities_expanded() raises:
    var events = _events("<p>&nbsp;&mdash;&hellip;&eacute;&copy;&rsquo;</p>")
    assert_equal(events[1].text, " —…é©’")


def test_numeric_entity_cp1252_remap() raises:
    # &#147;/&#148; are Windows-1252 curly quotes in the wild.
    var events = _events("<p>&#147;x&#148;</p>")
    assert_equal(events[1].text, "“x”")


def test_unknown_entity_preserved() raises:
    var events = _events("<p>&fakeent; ok</p>")
    assert_equal(events[1].text, "&fakeent; ok")


def test_bare_ampersand_preserved() raises:
    var events = _events("<p>fish & chips</p>")
    assert_equal(events[1].text, "fish & chips")


def test_lone_lt_is_text() raises:
    var events = _events("<p>a < b and 1<2</p>")
    assert_equal(len(events), 3)
    assert_equal(events[1].text, "a < b and 1<2")


def test_comment_and_doctype_skipped() raises:
    var events = _events("<!DOCTYPE html><!-- note --><p>x<!-- in --></p>")
    assert_equal(len(events), 3)
    assert_equal(events[0].name, "p")
    assert_equal(events[1].text, "x")


def test_processing_instruction_is_bogus_comment() raises:
    # HTML terminates '<?...' at the first '>', not '?>'.
    var events = _events("<?php echo 1 ?><p>x</p>")
    assert_equal(events[0].name, "p")


def test_end_tag_with_junk() raises:
    var events = _events('<div>x</div class="y" >')
    assert_equal(events[2].kind, EVENT_END)
    assert_equal(events[2].name, "div")


def test_tag_soup_does_not_raise() raises:
    var events = _events("<ul><li>a<li>b</ul><p>one<p>two")
    # Tokenizer reports what it sees; recovery is the mapping layer's job.
    assert_equal(events[0].name, "ul")
    assert_equal(events[1].name, "li")
    assert_equal(events[2].text, "a")
    assert_equal(events[3].name, "li")
    assert_equal(events[4].text, "b")
    assert_equal(events[5].kind, EVENT_END)
    assert_equal(events[5].name, "ul")


def test_meta_charset_latin1_transcoded() raises:
    # 0xE9 = é in Latin-1; declared via <meta charset>.
    var declared: String = '<meta charset="iso-8859-1"><p>'
    var raw = List[UInt8]()
    for b in declared.as_bytes():
        raw.append(b)
    raw.append(0xE9)
    for b in "</p>".as_bytes():
        raw.append(b)
    var source = String(StringSlice(unsafe_from_utf8=Span(raw)))
    var events = _events(source^)
    assert_equal(events[3].text, "é")


def test_invalid_utf8_replaced_lossily() raises:
    var raw_bytes = List[UInt8]()
    for b in "<p>a".as_bytes():
        raw_bytes.append(b)
    raw_bytes.append(0xFF)
    for b in "b</p>".as_bytes():
        raw_bytes.append(b)
    var source = String(StringSlice(unsafe_from_utf8=Span(raw_bytes)))
    var events = _events(source^)
    assert_equal(events[1].text, "a�b")


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def test_overlong_utf8_rejected() raises:
    # E0 80 80 is an overlong 3-byte encoding of U+0000. A conformant
    # decoder must reject it (each byte -> U+FFFD), never round-trip the
    # raw bytes into the resulting String.
    var overlong: List[UInt8] = [0xE0, 0x80, 0x80]
    var got = normalize_encoding_bytes(Span(overlong))
    assert_equal(got, "���")
    # And an overlong 4-byte encoding of U+0000 (F0 80 80 80).
    var overlong4: List[UInt8] = [0xF0, 0x80, 0x80, 0x80]
    var got4 = normalize_encoding_bytes(Span(overlong4))
    assert_equal(got4, "����")
    # A legitimate multi-byte codepoint must still survive intact.
    var euro: List[UInt8] = [0xE2, 0x82, 0xAC]  # U+20AC
    var got_euro = normalize_encoding_bytes(Span(euro))
    assert_equal(got_euro, "€")


def test_overlong_utf8_in_text_event() raises:
    # The overlong bytes embedded in element text must not poison the
    # emitted text event either.
    var raw_bytes = _bytes_of("<p>a")
    raw_bytes.append(0xE0)
    raw_bytes.append(0x80)
    raw_bytes.append(0x80)
    for b in "b</p>".as_bytes():
        raw_bytes.append(b)
    var source = String(StringSlice(unsafe_from_utf8=Span(raw_bytes)))
    var events = _events(source^)
    assert_equal(events[1].text, "a���b")


def test_truncated_tag_at_eof_liberal() raises:
    var events = _events("<p>x</p><a href=")
    assert_equal(events[3].kind, EVENT_START)
    assert_equal(events[3].name, "a")


def test_is_void_element() raises:
    assert_true(is_void_element("br"))
    assert_true(is_void_element("meta"))
    assert_true(not is_void_element("div"))
    assert_true(not is_void_element("a"))


def test_strict_mismatched_end_tag() raises:
    var tok = HtmlTokenizer("<div><span>x</div></span>", strict=True)
    with assert_raises(contains="mismatched end tag"):
        while True:
            var event = tok.next_event()
            if event.kind == EVENT_EOF:
                break


def test_strict_unknown_entity() raises:
    var tok = HtmlTokenizer("<p>&fakeent;</p>", strict=True)
    with assert_raises(contains="unknown entity"):
        while True:
            var event = tok.next_event()
            if event.kind == EVENT_EOF:
                break


def test_strict_accepts_valid_document() raises:
    var tok = HtmlTokenizer(
        (
            "<!DOCTYPE html><html><head><title>t</title></head>"
            "<body><p>x &amp; y</p><br></body></html>"
        ),
        strict=True,
    )
    while True:
        var event = tok.next_event()
        if event.kind == EVENT_EOF:
            break


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
