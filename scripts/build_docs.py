#!/usr/bin/env python3
"""Build the dependency-free ArchUnitZig documentation site."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path
import re
import shutil


SOURCE_PATTERN = re.compile(r"\{\{source:([^}]+)}}")
OUTPUT_MARKER = "archunitzig-docs-output.marker"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True, help="Repository root")
    parser.add_argument("--output", type=Path, required=True, help="Generated site directory")
    parser.add_argument("--api-docs", type=Path, required=True, help="Zig-generated API docs directory")
    return parser.parse_args()


def load_config(root: Path) -> dict:
    config_path = root / "docs-site" / "site.json"
    with config_path.open(encoding="utf-8") as handle:
        config = json.load(handle)
    if not config.get("pages"):
        raise ValueError("docs-site/site.json must define at least one page")
    return config


def page_href(current_slug: str, target_slug: str) -> str:
    prefix = "../" if current_slug else ""
    return f"{prefix}{target_slug}/" if target_slug else prefix or "./"


def root_prefix(slug: str) -> str:
    return "../" if slug else ""


def include_sources(fragment: str, root: Path) -> str:
    def replace(match: re.Match[str]) -> str:
        relative = match.group(1).strip().replace("\\", "/")
        source = (root / relative).resolve()
        try:
            source.relative_to(root)
        except ValueError as error:
            raise ValueError(f"source include leaves repository: {relative}") from error
        if not source.is_file():
            raise FileNotFoundError(f"source include does not exist: {relative}")
        code = html.escape(source.read_text(encoding="utf-8").replace("\r\n", "\n"))
        return (
            f'<pre data-source="{html.escape(relative, quote=True)}">'
            f'<code class="language-zig">{code}</code></pre>'
            f'<p class="source-caption">Compiled source: <code>{html.escape(relative)}</code></p>'
        )

    return SOURCE_PATTERN.sub(replace, fragment)


def render_nav(config: dict, current_slug: str) -> str:
    items = []
    for page in config["pages"]:
        current = ' aria-current="page"' if page["slug"] == current_slug else ""
        items.append(
            f'<li><a href="{page_href(current_slug, page["slug"])}"{current}>'
            f'{html.escape(page["label"])}</a></li>'
        )
    api_prefix = root_prefix(current_slug)
    items.append(f'<li><a href="{api_prefix}api/">API reference</a></li>')
    return "\n".join(items)


def render_page(root: Path, config: dict, page: dict, next_page: dict | None) -> str:
    slug = page["slug"]
    prefix = root_prefix(slug)
    source_path = root / "docs-site" / page["source"]
    fragment = source_path.read_text(encoding="utf-8")
    fragment = include_sources(fragment, root).replace("{{root}}", prefix)
    if "{{" in fragment:
        raise ValueError(f"unresolved placeholder in {source_path.relative_to(root)}")

    next_link = ""
    if next_page is not None:
        next_link = (
            f'<a class="next-page" href="{page_href(slug, next_page["slug"])}">'
            f'Next: {html.escape(next_page["label"])} <span aria-hidden="true">→</span></a>'
        )

    title = f'{page["title"]} · {config["site_title"]}'
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="{html.escape(page['description'], quote=True)}">
  <meta name="theme-color" content="#f5f2e9">
  <title>{html.escape(title)}</title>
  <link rel="stylesheet" href="{prefix}assets/site.css">
</head>
<body>
  <a class="skip-link" href="#main-content">Skip to content</a>
  <header class="site-header">
    <div class="header-inner">
      <a class="brand" href="{page_href(slug, '')}" aria-label="ArchUnitZig documentation home">
        <span class="brand-mark" aria-hidden="true">AU</span>
        <span>ArchUnitZig</span>
      </a>
      <nav class="header-links" aria-label="Project links">
        <a href="{prefix}api/">API</a>
        <a href="https://github.com/LukasNiessen/ArchUnitZig">GitHub</a>
        <a href="https://github.com/LukasNiessen/ArchUnitZig/issues">Issues</a>
      </nav>
    </div>
  </header>
  <div class="layout">
    <nav class="site-nav" aria-label="Documentation">
      <p class="nav-heading">Guide</p>
      <ul>
        {render_nav(config, slug)}
      </ul>
    </nav>
    <main class="content" id="main-content">
      <p class="eyebrow">Zig 0.16 · pre-release</p>
      {fragment}
      {next_link}
    </main>
  </div>
  <footer class="site-footer">
    <div class="footer-inner">
      <span>Architecture tests for Zig projects.</span>
      <span>Built from reviewed source with no remote runtime assets.</span>
    </div>
  </footer>
</body>
</html>
"""


def prepare_output(output: Path) -> None:
    if output.exists():
        marker = output / OUTPUT_MARKER
        if not marker.is_file() and any(output.iterdir()):
            raise ValueError(f"refusing to write into unmarked directory: {output}")
    else:
        output.mkdir(parents=True)


def main() -> None:
    args = parse_args()
    root = args.root.resolve()
    output = args.output.resolve()
    api_docs = args.api_docs.resolve()
    if not (root / "build.zig.zon").is_file():
        raise ValueError(f"not an ArchUnitZig repository root: {root}")
    if not (api_docs / "index.html").is_file():
        raise FileNotFoundError(f"Zig API docs are missing index.html: {api_docs}")
    config = load_config(root)
    prepare_output(output)
    (output / OUTPUT_MARKER).write_text("generated output\n", encoding="utf-8")
    shutil.copytree(root / "docs-site" / "assets", output / "assets", dirs_exist_ok=True)
    for index, page in enumerate(config["pages"]):
        destination = output if not page["slug"] else output / page["slug"]
        destination.mkdir(parents=True, exist_ok=True)
        next_page = config["pages"][index + 1] if index + 1 < len(config["pages"]) else None
        document = render_page(root, config, page, next_page)
        (destination / "index.html").write_text(document, encoding="utf-8", newline="\n")

    shutil.copytree(api_docs, output / "api", dirs_exist_ok=True)
    (output / ".nojekyll").write_text("", encoding="utf-8")
    (output / "robots.txt").write_text("User-agent: *\nAllow: /\n", encoding="utf-8")
    sitemap = "\n".join(
        f"  <url><loc>{config['base_url']}{page['slug'] + '/' if page['slug'] else ''}</loc></url>"
        for page in config["pages"]
    )
    sitemap += f"\n  <url><loc>{config['base_url']}api/</loc></url>"
    (output / "sitemap.xml").write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{sitemap}\n</urlset>\n',
        encoding="utf-8",
        newline="\n",
    )


if __name__ == "__main__":
    main()
