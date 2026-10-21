"""Check the offline help that is actually shipped, without Markdown build dependencies."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

from localization_bundle import LANGUAGES
from media_bundle_macho import inside

SECTION_IDS = ('contents', 'introduction', 'quick-start', 'features', 'settings',
               'troubleshooting', 'performance', 'shortcuts', 'version', 'appendix')


class HelpPage(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.language = None
        self.ids = set()
        self.links = []
        self.language_links = []
        self.current_languages = []
        self.feed(text)
        self.close()

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'html':
            self.language = attrs.get('lang')
        if 'id' in attrs:
            if attrs['id'] in self.ids:
                raise ValueError(f'Duplicate help section ID: {attrs["id"]}')
            self.ids.add(attrs['id'])
        for attribute in ('src', 'href'):
            if attribute in attrs:
                self.links.append(attrs[attribute])
        if 'data-help-language' in attrs:
            language = attrs['data-help-language']
            self.language_links.append((language, attrs.get('href')))
            if attrs.get('aria-current') == 'page':
                self.current_languages.append(language)


def readable_resource(root, relative):
    path = inside(root / relative, root)
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f'Missing or empty help resource: {relative}')
    return path


def verify_links(root, pages):
    for path, page in pages.items():
        for reference in page.links:
            link = urlsplit(reference)
            if link.scheme or link.netloc or link.path.startswith('/'):
                raise ValueError(f'Help link must be relative and offline: {reference}')
            target = inside(path.parent / unquote(link.path), root) if link.path else path
            if not target.is_file():
                raise ValueError(f'Missing help link target: {reference} in {path.name}')
            if link.fragment and (target not in pages or unquote(link.fragment) not in pages[target].ids):
                raise ValueError(f'Missing help section: {reference} in {path}')


def verify_help_bundle(directory):
    root = Path(directory).absolute()
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f'Missing or invalid help directory: {root}')
    for name in ('help.css', 'help.js'):
        readable_resource(root, name)
    pages = {}
    report = {}
    for language in LANGUAGES:
        path = readable_resource(root, f'{language}/index.html')
        page = HelpPage(path.read_text())
        if page.language != language:
            raise ValueError(f'Incorrect help language: {path}')
        expected_links = [(code, f'../{code}/index.html') for code in LANGUAGES]
        if page.language_links != expected_links or page.current_languages != [language]:
            raise ValueError(f'Incorrect help language navigation: {language}')
        if not set(SECTION_IDS).issubset(page.ids):
            raise ValueError(f'Missing help chapters: {language}')
        pages[path] = page
        report[language] = {'sections': sorted(page.ids)}
    if len({tuple(value['sections']) for value in report.values()}) != 1:
        raise ValueError('Help translations must have matching section IDs')
    verify_links(root, pages)
    return report
