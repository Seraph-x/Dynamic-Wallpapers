#!/usr/bin/env python3
"""Render the five Markdown guides to bundled, offline HTML. --check never writes."""
import argparse
from html import escape
import json
from pathlib import Path
import re
import sys

from help_bundle import verify_help_bundle
from product_configuration import load as load_product_configuration


def render_page(source, language, labels, *, product_name, languages):
    import markdown

    title = source.splitlines()[0].removeprefix('# ')
    body, count = re.subn(r'<!-- help-languages -->.*?<!-- /help-languages -->', '', source, flags=re.S)
    if count != 1:
        raise ValueError(f'{language}: expected exactly one Markdown language navigation block')
    content = markdown.markdown(body, extensions=['tables', 'attr_list', 'sane_lists'], output_format='html')
    content = content.replace('<table>',
        f'<div class="table-scroll" role="region" tabindex="0" aria-label="{escape(labels[language]["table"])}"><table>')
    content = content.replace('</table>', '</table></div>').replace('<th>', '<th scope="col">')
    navigation = '\n'.join(
        f'<a href="../{code}/index.html" lang="{code}" hreflang="{code}" data-help-language="{code}"'
        + (' aria-current="page"' if code == language else '')
        + f'>{escape(labels[code]["name"])}</a>' for code in languages)
    return f'''<!doctype html>
<html lang="{language}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'">
<title>{escape(title)}</title>
<link rel="stylesheet" href="../help.css">
<script src="../help.js" defer></script>
</head>
<body>
<a class="skip-link" href="#main">{escape(labels[language]["skip"])}</a>
<header>
<div class="brand">{escape(product_name)}</div>
<nav class="languages" aria-label="{escape(labels[language]["switcher"])}">
<span>{escape(labels[language]["switcher"])}</span>
{navigation}
</nav>
</header>
<main id="main">
{content}
</main>
<footer><a href="#contents">{escape(labels[language]["contents"])}</a></footer>
</body>
</html>
'''


def generated_files(root):
    configuration = load_product_configuration(root / 'scripts/product-configuration.json')
    source = root / 'docs/help'
    labels = json.loads((source / 'languages.json').read_text())
    if tuple(labels) != configuration.localizations:
        raise ValueError('Help navigation must match product localizations')
    documents = [source / f'{language}.md' for language in configuration.localizations]
    documents.append(source / 'README.md')
    for path in documents:
        text = path.read_text()
        heading = '\n'.join(text.splitlines()[:8])
        version_build = (
            rf'v{re.escape(configuration.version)}[^\n]*\b{re.escape(configuration.build)}\b')
        if re.search(version_build, heading) is None:
            raise ValueError(
                f'{path.relative_to(root)} must name configured version/build '
                f'{configuration.version}/{configuration.build}')
    output = {
        f'{language}/index.html': render_page(
            (source / f'{language}.md').read_text(), language, labels,
            product_name=configuration.application.display_name,
            languages=configuration.localizations)
        for language in configuration.localizations
    }
    output.update({name: (source / name).read_text() for name in ('help.css', 'help.js')})
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if bundled pages differ from their sources')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = root / 'Sources/WallpaperApp/Help'
    for relative, content in generated_files(root).items():
        path = destination / relative
        if args.check:
            if not path.is_file() or path.read_text() != content:
                raise ValueError(f'Stale or missing help output: {relative}; run scripts/build-help.py')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    report = verify_help_bundle(destination)
    print(f'Help {"verified" if args.check else "generated"}: {len(report)} languages; offline links and section IDs valid')


if __name__ == '__main__':
    try:
        main()
    except ImportError as error:
        print(f'HELP BUILD FAILED: {error}. Install scripts/help-requirements.txt in your Python environment.', file=sys.stderr)
        raise SystemExit(1)
    except (OSError, ValueError) as error:
        print(f'HELP BUILD FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
