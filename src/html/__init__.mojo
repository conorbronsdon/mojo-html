"""Liberal HTML parsing and readable-text extraction for Mojo (mojo-html)."""

from html.extract import (
    extract,
    main_text,
    main_text_confident,
    MainContent,
    Page,
    Heading,
    Link,
)
from html.tokenizer import (
    HtmlTokenizer,
    HtmlEvent,
    is_void_element,
    normalize_encoding,
    normalize_encoding_bytes,
    EVENT_START,
    EVENT_END,
    EVENT_TEXT,
    EVENT_EOF,
)
