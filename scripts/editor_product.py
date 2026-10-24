"""Independent Editor identity, validated before use as bundle paths or metadata."""
from dataclasses import replace
import json
from pathlib import Path
import re

from product_configuration import (BundleConfiguration, CEFHelperConfiguration,
                                   load, reject_duplicate_pairs)

KEYS = frozenset({'name', 'executable', 'bundleIdentifier', 'version', 'build',
                  'minimumMacOS', 'architecture', 'urlScheme'})


def validate(product):
    if type(product) is not dict or set(product) != KEYS:
        raise ValueError('Editor product must contain exactly the documented keys')
    if any(type(value) is not str or not value for value in product.values()):
        raise ValueError('Editor product values must be nonempty strings')
    for key in ('name', 'executable'):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9 _-]*', product[key]):
            raise ValueError(f'Invalid Editor {key}')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9-]*)+', product['bundleIdentifier']):
        raise ValueError('Invalid Editor bundle identifier')
    if not re.fullmatch(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', product['version']):
        raise ValueError('Editor version must be a three-part release version')
    if not re.fullmatch(r'[1-9][0-9]*', product['build']):
        raise ValueError('Editor build must be a positive decimal string')
    if (product['minimumMacOS'], product['architecture'], product['urlScheme']) != (
            '14.0', 'arm64', 'dynamic-wallpaper-editor'):
        raise ValueError('Unsupported Editor platform or URL scheme')
    # The native runtime and protocol deliberately use these stable identities.
    if product['bundleIdentifier'] != 'local.dynamicwallpaper.editor' or product['executable'] != 'DynamicWallpaperEditor':
        raise ValueError('Editor identity differs from its native protocol')
    return product


def load_editor_product(path):
    return validate(json.loads(Path(path).read_text(), object_pairs_hook=reject_duplicate_pairs))


def configuration(root, product):
    validate(product)
    main = load(Path(root) / 'scripts/product-configuration.json')
    return replace(main, version=product['version'], build=product['build'],
                   application=BundleConfiguration(product['bundleIdentifier'], product['name'],
                       product['name'] + '.app', product['executable'], product['executable']),
                   cef_helpers=tuple(CEFHelperConfiguration(helper.role, helper.suffix,
                       product['bundleIdentifier'] + '.helper.' + helper.role) for helper in main.cef_helpers))


def helper_configuration(root, product):
    return configuration(root, product).as_document()


def application_metadata(root, product):
    config = configuration(root, product)
    main = load(Path(root) / 'scripts/product-configuration.json')
    return {'CFBundleIdentifier': product['bundleIdentifier'], 'CFBundleName': product['name'],
            'CFBundleDisplayName': product['name'], 'CFBundleExecutable': product['executable'],
            'CFBundleShortVersionString': product['version'], 'CFBundleVersion': product['build'],
            'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon',
            'LSMinimumSystemVersion': product['minimumMacOS'], 'LSUIElement': False,
            'NSHighResolutionCapable': True, 'CFBundleDevelopmentRegion': 'en',
            'CFBundleLocalizations': list(config.localizations), 'DWEditorExchangeAPI': '1',
            'DWHostBundleIdentifier': main.application.bundle_identifier,
            'CFBundleURLTypes': [{'CFBundleURLName': product['bundleIdentifier'] + '.exchange',
                                  'CFBundleURLSchemes': [product['urlScheme']]}]}
