"""Pull title, metadata, and main-content text out of an HTML page — the
"clean article text" workflow this library exists for.

Usage:
    mojo run -I src examples/extract_article.mojo <page.html>
"""

from std.sys import argv

from html import extract, main_text_confident


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: extract_article <page.html>")
        return

    var source = open(String(args[1]), "r").read()
    var page = extract(source.copy())

    print("title:", page.title)
    print("description:", page.meta_description)

    var main = main_text_confident(source^)
    print("confident:", main.confident)
    print()

    var excerpt_len = 500
    if main.text.byte_length() < excerpt_len:
        excerpt_len = main.text.byte_length()
    var bytes = main.text.as_bytes()
    print(String(StringSlice(unsafe_from_utf8=bytes[0:excerpt_len])))
