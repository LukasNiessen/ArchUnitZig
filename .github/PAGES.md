# Documentation site

The guide is built from `docs-site/site.json`, authored fragments in `docs-site/pages`, the local
stylesheet in `docs-site/assets`, canonical compiled examples under `test`, and Zig-generated API
documentation for the public `archunit` module.

## Build and preview

Use Zig 0.16.0 and Python 3.11 or newer:

```console
zig build docs
python -m http.server --directory zig-out/docs-site 8000
```

Open `http://localhost:8000`. Zig gives the builder a cache-owned output directory; after validation,
the build installs it at `zig-out/docs-site`. `scripts/check_docs.py` runs before that installation.

## Publishing contract

`.github/workflows/docs.yml` builds and uploads an ordinary artifact on pushes, pull requests, and
manual runs. That job needs no Pages configuration or secrets, so it remains usable in forks.

Deployment runs only for a push to `main` in `LukasNiessen/ArchUnitZig`. The deploy job downloads the
already-validated ordinary artifact, configures Pages, packages the Pages artifact, and deploys it
with job-scoped `pages: write` and `id-token: write` permissions. Configure the repository's Pages
source as **GitHub Actions** before the first upstream deployment.

## Editing

- Keep one `<h1>` in each authored fragment; the builder supplies the surrounding page landmarks.
- Use `{{root}}` for site-root-relative links and `{{source:path/to/example.zig}}` for compiled code.
- Do not add remote scripts, stylesheets, fonts, images, or runtime services for core reading.
- Run `zig build docs` after changing content, navigation, examples, API declarations, or styling.
