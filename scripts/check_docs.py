#!/usr/bin/env python3
"""Validate the generated ArchUnitZig documentation site without third-party packages."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ElementTree


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.duplicate_ids: set[str] = set()
        self.links: list[str] = []
        self.runtime_assets: list[str] = []
        self.title_parts: list[str] = []
        self.in_title = False
        self.h1_count = 0
        self.main_ids: list[str | None] = []
        self.skip_links = 0
        self.nav_labels: list[str | None] = []
        self.remote_runtime: list[str] = []
        self.html_lang: str | None = None
        self.has_viewport = False
        self.has_description = False
        self.current_page_links = 0
        self.script_count = 0
        self.images_missing_alt = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        element_id = values.get("id")
        if element_id:
            if element_id in self.ids:
                self.duplicate_ids.add(element_id)
            self.ids.add(element_id)
        if tag == "html":
            self.html_lang = values.get("lang")
        elif tag == "title":
            self.in_title = True
        elif tag == "h1":
            self.h1_count += 1
        elif tag == "main":
            self.main_ids.append(element_id)
        elif tag == "nav":
            self.nav_labels.append(values.get("aria-label"))
        elif tag == "meta":
            if values.get("name") == "viewport":
                self.has_viewport = True
            if values.get("name") == "description" and values.get("content", "").strip():
                self.has_description = True
        elif tag == "a":
            href = values.get("href")
            if href:
                self.links.append(href)
                if href == "#main-content" and "skip-link" in values.get("class", "").split():
                    self.skip_links += 1
            if values.get("aria-current") == "page":
                self.current_page_links += 1
        elif tag == "script":
            self.script_count += 1
        elif tag == "img" and values.get("alt") is None:
            self.images_missing_alt += 1

        runtime_attr = "href" if tag == "link" else "src" if tag in {"script", "img", "iframe"} else None
        runtime_value = values.get(runtime_attr) if runtime_attr else None
        if runtime_value:
            self.runtime_assets.append(runtime_value)
            if urlsplit(runtime_value).scheme in {"http", "https"}:
                self.remote_runtime.append(runtime_value)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False

    def handle_data(self, data: str) -> None:
        if self.in_title:
            self.title_parts.append(data)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True, help="Repository root")
    parser.add_argument("--site", type=Path, required=True, help="Generated site directory")
    return parser.parse_args()


def resolve_internal_link(page: Path, site: Path, href: str) -> tuple[Path, str]:
    parsed = urlsplit(href)
    path = unquote(parsed.path)
    target = (page.parent / path).resolve() if path else page.resolve()
    if path.endswith("/") or target.is_dir():
        target = target / "index.html"
    return target, unquote(parsed.fragment)


def check_page(page: Path, site: Path, *, authored: bool) -> list[str]:
    errors: list[str] = []
    parser = PageParser()
    source = page.read_text(encoding="utf-8")
    parser.feed(source)
    relative = page.relative_to(site).as_posix()

    if authored:
        if parser.html_lang != "en":
            errors.append(f"{relative}: html lang must be en")
        if not "".join(parser.title_parts).strip():
            errors.append(f"{relative}: non-empty title is required")
        if not parser.has_viewport:
            errors.append(f"{relative}: viewport metadata is required")
        if not parser.has_description:
            errors.append(f"{relative}: description metadata is required")
        if parser.h1_count != 1:
            errors.append(f"{relative}: expected exactly one h1, found {parser.h1_count}")
        if parser.main_ids != ["main-content"]:
            errors.append(f"{relative}: one main#main-content landmark is required")
        if parser.skip_links != 1:
            errors.append(f"{relative}: one skip link is required")
        if any(not label for label in parser.nav_labels):
            errors.append(f"{relative}: every nav needs an aria-label")
        if parser.current_page_links != 1:
            errors.append(f"{relative}: expected one aria-current page link")
        if parser.script_count:
            errors.append(f"{relative}: guide pages must work without scripts")
        if parser.images_missing_alt:
            errors.append(f"{relative}: image missing alt text")
        if parser.duplicate_ids:
            errors.append(f"{relative}: duplicate ids: {', '.join(sorted(parser.duplicate_ids))}")
        if "{{" in source:
            errors.append(f"{relative}: unresolved template placeholder")

    if parser.remote_runtime:
        errors.append(f"{relative}: remote runtime assets: {', '.join(parser.remote_runtime)}")

    for href in parser.links + parser.runtime_assets:
        parsed = urlsplit(href)
        if parsed.scheme in {"http", "https", "mailto", "data"}:
            continue
        target, fragment = resolve_internal_link(page, site, href)
        try:
            target.relative_to(site)
        except ValueError:
            errors.append(f"{relative}: link leaves site: {href}")
            continue
        if not target.is_file():
            errors.append(f"{relative}: missing link target: {href}")
            continue
        if fragment and target.suffix.lower() == ".html":
            target_parser = PageParser()
            target_parser.feed(target.read_text(encoding="utf-8"))
            if fragment not in target_parser.ids:
                errors.append(f"{relative}: missing fragment target: {href}")
    return errors


def main() -> None:
    args = parse_args()
    root = args.root.resolve()
    site = args.site.resolve()
    with (root / "docs-site" / "site.json").open(encoding="utf-8") as handle:
        config = json.load(handle)

    required = {
        site / "index.html",
        site / "assets" / "site.css",
        site / "api" / "index.html",
        site / "api" / "main.js",
        site / "api" / "main.wasm",
        site / "api" / "sources.tar",
        site / ".nojekyll",
        site / "robots.txt",
        site / "sitemap.xml",
    }
    authored_pages: list[Path] = []
    for page in config["pages"]:
        generated = site / page["slug"] / "index.html" if page["slug"] else site / "index.html"
        required.add(generated)
        authored_pages.append(generated)

    errors = [f"missing required artifact: {path.relative_to(site).as_posix()}" for path in required if not path.is_file()]
    if errors:
        raise SystemExit("documentation validation failed:\n- " + "\n- ".join(sorted(errors)))

    css = (site / "assets" / "site.css").read_text(encoding="utf-8")
    for required_css in ("@media (max-width:", ":focus-visible", "overflow-wrap:", "prefers-reduced-motion"):
        if required_css not in css:
            errors.append(f"assets/site.css: missing responsive/accessibility rule {required_css!r}")

    for page in authored_pages:
        errors.extend(check_page(page, site, authored=True))

    # Compiler-generated API docs are deliberately not held to the authored-page template,
    # but their entry point and all of its local file links must remain self-contained.
    errors.extend(check_page(site / "api" / "index.html", site, authored=False))

    source_attributes = "\n".join(page.read_text(encoding="utf-8") for page in authored_pages)
    expected_sources = {
        "test/fixtures/readme-consumer/build.zig",
        "test/fixtures/readme-consumer/test/architecture.zig",
        "test/readme/files.zig",
        "test/readme/layers.zig",
        "test/readme/slices.zig",
        "test/readme/graph.zig",
        "test/readme/metrics.zig",
        "test/readme/testing.zig",
    }
    for source in expected_sources:
        if f'data-source="{source}"' not in source_attributes:
            errors.append(f"canonical compiled example is not embedded: {source}")

    sitemap_root = ElementTree.parse(site / "sitemap.xml").getroot()
    namespace = {"sitemap": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    actual_urls = {element.text for element in sitemap_root.findall("sitemap:url/sitemap:loc", namespace)}
    expected_urls = {
        f"{config['base_url']}{page['slug'] + '/' if page['slug'] else ''}" for page in config["pages"]
    }
    expected_urls.add(f"{config['base_url']}api/")
    if actual_urls != expected_urls:
        errors.append("sitemap URLs do not match the configured guide and API pages")

    if errors:
        raise SystemExit("documentation validation failed:\n- " + "\n- ".join(sorted(set(errors))))
    print(f"documentation validation passed: {len(authored_pages)} guide pages + compiler API docs")


if __name__ == "__main__":
    main()
