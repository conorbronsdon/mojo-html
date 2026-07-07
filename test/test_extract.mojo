from std.testing import assert_equal, assert_true, assert_false, TestSuite

from html.extract import extract, main_text, main_text_confident, Page


def test_metadata_basics() raises:
    var page = extract(
        '<html lang="en"><head><title>My Page</title>'
        '<meta name="description" content="A page about things.">'
        '<link rel="canonical" href="https://example.org/p">'
        "</head><body><p>hi</p></body></html>"
    )
    assert_equal(page.title, "My Page")
    assert_equal(page.meta_description, "A page about things.")
    assert_equal(page.canonical_url, "https://example.org/p")
    assert_equal(page.lang, "en")
    assert_equal(page.text, "hi")


def test_og_title_fallback() raises:
    var page = extract(
        '<head><meta property="og:title" content="OG Title"></head>'
        "<body><p>x</p></body>"
    )
    assert_equal(page.title, "OG Title")


def test_og_description_fallback() raises:
    var page = extract(
        '<head><meta property="og:description" content="From OG."></head>'
        "<body><p>x</p></body>"
    )
    assert_equal(page.meta_description, "From OG.")


def test_title_entity_decoded() raises:
    var page = extract("<title>Q&amp;A &mdash; part 1</title><p>x</p>")
    assert_equal(page.title, "Q&A — part 1")


def test_title_only_first_nonempty() raises:
    # An SVG icon in the body carries its own <title>; only the document's
    # first non-empty <title> should be captured, not a concatenation.
    var page = extract(
        "<html><head><title>Real Article Title</title></head>"
        "<body><h1>Heading</h1><p>Body text.</p>"
        '<svg viewBox="0 0 16 16"><title>search icon</title></svg>'
        "<p>More text.</p></body></html>"
    )
    assert_equal(page.title, "Real Article Title")


def test_title_first_empty_then_real() raises:
    # An empty leading <title> must not lock out a later real one.
    var page = extract(
        "<html><head><title></title><title>Second Title</title></head>"
        "<body><p>x</p></body></html>"
    )
    assert_equal(page.title, "Second Title")


def test_block_elements_produce_newlines() raises:
    var page = extract("<body><p>one</p><p>two</p><div>three</div></body>")
    assert_equal(page.text, "one\ntwo\nthree")


def test_whitespace_collapsed_within_blocks() raises:
    var page = extract("<p>  a\n\t  b  </p><p>c&nbsp; d</p>")
    assert_equal(page.text, "a b\nc d")


def test_br_breaks_line() raises:
    var page = extract("<p>line one<br>line two</p>")
    assert_equal(page.text, "line one\nline two")


def test_inline_elements_do_not_break() raises:
    var page = extract("<p>a <b>bold</b> and <i>italic</i> word</p>")
    assert_equal(page.text, "a bold and italic word")


def test_script_style_nav_excluded() raises:
    var page = extract(
        "<body><nav><a href='/x'>Menu</a></nav>"
        "<script>var hidden = 1;</script>"
        "<style>p{color:red}</style>"
        "<noscript>enable js</noscript>"
        "<template><p>tpl</p></template>"
        "<p>visible</p></body>"
    )
    assert_equal(page.text, "visible")


def test_head_text_excluded() raises:
    var page = extract(
        "<head><title>T</title></head><body><p>body text</p></body>"
    )
    assert_equal(page.text, "body text")
    assert_equal(page.title, "T")


def test_headings_collected() raises:
    var page = extract(
        "<h1>Top</h1><p>x</p><h2>Sub <em>two</em></h2><h3>Deep</h3>"
    )
    assert_equal(len(page.headings), 3)
    assert_equal(page.headings[0].level, 1)
    assert_equal(page.headings[0].text, "Top")
    assert_equal(page.headings[1].level, 2)
    assert_equal(page.headings[1].text, "Sub two")
    assert_equal(page.headings[2].level, 3)


def test_links_collected() raises:
    var page = extract(
        '<body><p>See <a href="https://a.example/">site A</a> and '
        '<a href="/b">the <b>B</b> page</a>.</p></body>'
    )
    assert_equal(len(page.links), 2)
    assert_equal(page.links[0].href, "https://a.example/")
    assert_equal(page.links[0].text, "site A")
    assert_equal(page.links[1].href, "/b")
    assert_equal(page.links[1].text, "the B page")


def test_anchor_without_href_ignored() raises:
    var page = extract('<body><a name="top">anchor</a></body>')
    assert_equal(len(page.links), 0)


def test_tag_soup_unclosed_p_li() raises:
    var page = extract("<ul><li>one<li>two</ul><p>para1<p>para2")
    assert_equal(page.text, "one\ntwo\npara1\npara2")


def test_crossed_tags_recovered() raises:
    var page = extract("<div><p>a</div>b")
    assert_equal(page.text, "a\nb")


def test_table_rows_break_cells_join() raises:
    var page = extract(
        "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>"
    )
    assert_equal(page.text, "a b\nc")


def test_unquoted_attr_link() raises:
    var page = extract("<body><a href=/rel/path>go</a></body>")
    assert_equal(page.links[0].href, "/rel/path")


def test_main_text_prefers_article() raises:
    var text = main_text(
        "<body><div>huge sidebar text that is quite long and rambles on "
        "and on and on far longer than the article itself does</div>"
        "<article><p>the story</p></article></body>"
    )
    assert_equal(text, "the story")


def test_main_text_density_fallback() raises:
    var text = main_text(
        "<body><header><p>site chrome</p></header>"
        "<div id=nav-ish><p>short menu</p></div>"
        "<div id=content><p>This is the long main body of the page with "
        "many words in it, clearly the densest text on the page.</p>"
        "<p>And a second paragraph too.</p></div>"
        "<footer><p>copyright</p></footer></body>"
    )
    assert_true(text.startswith("This is the long main body"))
    assert_true("second paragraph" in text)
    assert_true("site chrome" not in text)
    assert_true("copyright" not in text)


def test_main_text_no_containers_falls_back() raises:
    var text = main_text("<body><p>only text</p></body>")
    assert_equal(text, "only text")


# --- integration: real fixtures -------------------------------------------


def test_example_com() raises:
    var page = extract(open("test/data/example_com.html", "r").read())
    assert_equal(page.title, "Example Domain")
    assert_true("documentation examples" in page.text)
    assert_equal(len(page.links), 1)
    assert_true(page.links[0].href.startswith("https://"))
    assert_equal(page.lang, "en")


def test_substack_article() raises:
    var page = extract(open("test/data/substack_article.html", "r").read())
    assert_true(page.title.byte_length() > 0)
    assert_true("Kraken" in page.title)
    assert_true(page.meta_description.byte_length() > 0)
    assert_true(page.text.byte_length() > 2000)
    assert_true(len(page.links) > 10)
    assert_true(len(page.headings) > 0)


def test_substack_main_text() raises:
    var text = main_text(open("test/data/substack_article.html", "r").read())
    assert_true(text.byte_length() > 1000)


def test_pg_essay() raises:
    var page = extract(open("test/data/pg_essay.html", "r").read())
    assert_equal(page.title, "How to Do Great Work")
    assert_true(page.text.byte_length() > 10000)
    assert_true(len(page.links) > 0)


# --- scorer regression + confidence ---------------------------------------


def test_sidebar_heavy_extracts_article_only() raises:
    var text = main_text(
        "<body><nav><a href=/1>Home</a><a href=/2>About</a></nav>"
        "<aside><h3>Related posts</h3><ul><li><a href=/x>Sidebar One</a></li>"
        "<li><a href=/y>Sidebar Two</a></li></ul></aside>"
        "<article><h1>Headline</h1><p>This is the real article body, with "
        "several commas, and plenty of words, long enough to clear the "
        "confidence gate and read like genuine prose from the page.</p>"
        "<p>A second paragraph continues the story with more detail.</p>"
        "</article></body>"
    )
    assert_true("real article body" in text)
    assert_true("second paragraph" in text)
    assert_true("Home" not in text)
    assert_true("About" not in text)
    assert_true("Sidebar One" not in text)
    assert_true("Related posts" not in text)


def test_div_soup_div_as_p() raises:
    # No <article>/<main>, no class hints on the content: the div-as-p rule
    # must find the nested-div paragraph and reject the link-only sidebar.
    var text = main_text(
        "<body><div><div>A moderately long paragraph of text inside nested "
        "divs with several, commas, to, score, well, and enough length to "
        "exceed the twenty five char minimum by a wide margin here.</div>"
        "</div><div class=sidebar><a href=/a>alpha</a> <a href=/b>beta</a> "
        "<a href=/c>gamma</a></div></body>"
    )
    assert_true("moderately long paragraph" in text)
    assert_true("alpha" not in text)
    assert_true("gamma" not in text)


def test_low_confidence_paywall_stub() raises:
    var mc = main_text_confident(
        "<body><article><p>Subscribe to read more.</p></article></body>"
    )
    assert_false(mc.confident)
    assert_true("Subscribe to read more" in mc.text)


def test_confident_on_real_article() raises:
    var mc = main_text_confident(
        "<body><article><p>This is a genuine article body with enough words, "
        "several commas, and real sentences to comfortably clear both the "
        "one hundred forty character gate and the minimum score threshold "
        "that the readability scorer applies before it claims confidence.</p>"
        "</article></body>"
    )
    assert_true(mc.confident)


# --- integration: docs.python.org (high link density, [role=main]) --------


def test_docs_python_extract() raises:
    var page = extract(open("test/data/docs_python.html", "r").read())
    assert_true("Informal Introduction to Python" in page.title)
    assert_true(page.text.byte_length() > 5000)
    assert_true(len(page.links) > 20)


def test_docs_python_main_text() raises:
    var mc = main_text_confident(
        open("test/data/docs_python.html", "r").read()
    )
    assert_true(mc.confident)
    # body prose is present ...
    assert_true("Comments in Python" in mc.text)
    assert_true("hash character" in mc.text)
    # ... and the surrounding <nav> chrome is not.
    assert_true("Quick search" not in mc.text)
    assert_true("Navigation" not in mc.text)


# --- integration: danluu.com (minimal markup, no class hints) --------------


def test_danluu_extract() raises:
    var page = extract(open("test/data/danluu_article.html", "r").read())
    assert_equal(page.title, "Computer latency: 1977-2017")
    assert_true(page.text.byte_length() > 10000)


def test_danluu_main_text() raises:
    # Pure tag scoring (plus the single <main> region) must find the body.
    var mc = main_text_confident(
        open("test/data/danluu_article.html", "r").read()
    )
    assert_true(mc.confident)
    assert_true(mc.text.byte_length() > 10000)
    assert_true("nagging feeling" in mc.text)
    assert_true("computer latency" in mc.text)


# --- integration: substack widget exclusion (scorer regression) -----------


def test_substack_main_text_excludes_widgets() raises:
    var text = main_text(open("test/data/substack_article.html", "r").read())
    # The article body wins ...
    assert_true("skyrocketing AI token bill" in text)
    assert_true(text.byte_length() > 1000)
    # ... and the share/subscribe/comment widget chrome the v0.1 "largest
    # container" heuristic leaked is gone.
    assert_true("Share" not in text)
    assert_true("Sign in" not in text)
    assert_true("Type your email" not in text)
    assert_true("Leave a comment" not in text)


def _flood_doc(n: Int) -> String:
    var html = String("<html><body>")
    for _ in range(n):
        html += "<div>"
    for _ in range(n):
        html += "</span>"  # stray: no <span> is open, must be ignored
    html += "<p>The quick brown fox jumps over the lazy dog.</p>"
    html += "</body></html>"
    return html^


def test_stray_end_tag_flood_is_bounded() raises:
    # A deep stack of unclosed <div> plus a flood of stray </span> end tags
    # used to be O(n^2): each stray forced a full-stack scan in
    # _nearest_open. The per-tag-name open count now rejects them in O(1).
    # This asserts the liberal-recovery behavior (strays ignored, real
    # content still extracted) on that pattern; the wall-clock proof of the
    # O(n^2) -> O(n) fix lives in the standalone DoS repro in the PR.
    var html = _flood_doc(2000)
    var page = extract(html.copy())
    assert_equal(page.text, "The quick brown fox jumps over the lazy dog.")
    var mt = main_text(html^)
    assert_true("quick brown fox" in mt)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
