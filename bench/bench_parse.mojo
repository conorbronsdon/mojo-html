"""Throughput benchmark for `extract` and `main_text_confident` over the
saved-page test corpus.

Reports wall-clock per parse and MB/s. Run compiled for meaningful numbers:
`mojo build -I src bench/bench_parse.mojo -o .bench_parse && ./.bench_parse`
(or `pixi run bench`). The corpus is the same set of real pages the extraction
tests use, so the benchmark measures the real parse + readability path.
"""
from std.time import perf_counter_ns

from html import extract, main_text_confident


def bench(path: String, iterations: Int) raises:
    var source = open(path, "r").read()
    var size_mb = Float64(source.byte_length()) / (1024.0 * 1024.0)

    # Warmup + correctness anchor: extract once, require stable output size.
    var warm = extract(source.copy())
    var n = warm.text.byte_length()
    var start = perf_counter_ns()
    for _ in range(iterations):
        var page = extract(source.copy())
        if page.text.byte_length() != n:
            raise Error("inconsistent extract")
    var extract_ms = (
        Float64(perf_counter_ns() - start) / Float64(iterations) / 1e6
    )

    var main_warm = main_text_confident(source.copy())
    var m = main_warm.text.byte_length()
    start = perf_counter_ns()
    for _ in range(iterations):
        var main = main_text_confident(source.copy())
        if main.text.byte_length() != m:
            raise Error("inconsistent main_text_confident")
    var main_ms = Float64(perf_counter_ns() - start) / Float64(iterations) / 1e6

    print(path)
    print(t"  {source.byte_length()} bytes, {n} extracted text bytes:")
    print(
        t"  extract: {extract_ms} ms/parse,"
        t" {size_mb / (extract_ms / 1000.0)} MB/s"
    )
    print(
        t"  main_text_confident: {main_ms} ms/parse,"
        t" {size_mb / (main_ms / 1000.0)} MB/s"
    )


def main() raises:
    bench("test/data/example_com.html", 500)
    bench("test/data/danluu_article.html", 100)
    bench("test/data/docs_python.html", 100)
    bench("test/data/pg_essay.html", 100)
    bench("test/data/substack_article.html", 50)
