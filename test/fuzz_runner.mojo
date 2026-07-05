"""Fuzz target: parse argv[1] via extract(); raising is fine, crashing or
hanging is not. Also exercises the main-content scorer."""

from std.sys import argv

from html.extract import extract, main_text_confident


def main():
    try:
        var source = open(String(argv()[1]), "r").read()
        var page = extract(source.copy())
        var mc = main_text_confident(source^)
        print(
            "title_len:",
            page.title.byte_length(),
            "text_len:",
            page.text.byte_length(),
            "links:",
            len(page.links),
            "main_len:",
            mc.text.byte_length(),
            "confident:",
            mc.confident,
        )
    except e:
        print("raised:", e)
