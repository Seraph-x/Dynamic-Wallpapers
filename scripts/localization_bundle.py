"""Copy the SwiftPM localization bundle belonging to the packaged executable."""
import plistlib
import shutil

from media_bundle_macho import inside, sha256
from product_configuration import load as load_product_configuration

RESOURCE_BUNDLE = 'DynamicWallpaper_WallpaperApp.bundle'
CONFIG = load_product_configuration()
LANGUAGES = CONFIG.localizations
DEVELOPMENT_LANGUAGE = CONFIG.development_localization


def bundle_resource_directory(resources):
    """Support flat SwiftPM bundles and native macOS bundles emitted by Swift Build."""
    if not resources.is_dir() or resources.is_symlink():
        raise ValueError(f'Missing or invalid localization bundle: {resources}')
    directory = resources / 'Contents/Resources' if (resources / 'Contents').exists() else resources
    directory = inside(directory, resources)
    if not directory.is_dir():
        raise ValueError(f'Missing localization resource directory: {directory}')
    return directory


def verify_localizations(resources, configuration=CONFIG):
    directory = bundle_resource_directory(resources)
    info_path = resources / ('Contents/Info.plist' if directory != resources.resolve() else 'Info.plist')
    required = [info_path]
    for language in configuration.localizations:
        matches = [path for path in directory.iterdir() if path.name.casefold() == f'{language}.lproj'.casefold()]
        if len(matches) != 1:
            raise ValueError(f'Missing or ambiguous localization resource: {language}.lproj')
        required.append(matches[0] / 'Localizable.strings')
        required.append(matches[0] / 'InfoPlist.strings')
    for path in required:
        path = inside(path, resources)
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing localization resource: {path.relative_to(resources.resolve())}')
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleDevelopmentRegion') != configuration.development_localization:
        raise ValueError(
            f'The localization bundle must declare {configuration.development_localization} '
            'as its development language')


def prepare_localizations(binary, app, configuration=CONFIG):
    source = binary.parent / RESOURCE_BUNDLE
    verify_localizations(source, configuration)
    destination = app / 'Contents/Resources' / RESOURCE_BUNDLE
    shutil.copytree(source, destination, symlinks=True)
    verify_localizations(destination, configuration)
    directory = bundle_resource_directory(destination)
    for language in configuration.localizations:
        localized = next(path for path in directory.iterdir() if path.name.casefold() == f'{language}.lproj'.casefold())
        target = app / 'Contents/Resources' / f'{language}.lproj'
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(localized / 'InfoPlist.strings', target / 'InfoPlist.strings')
    return {str(path.relative_to(destination)): sha256(path)
            for path in sorted(destination.rglob('*')) if path.is_file()}


def verify_application_localizations(app, info, configuration=CONFIG):
    if (info.get('CFBundleDevelopmentRegion') != configuration.development_localization
            or info.get('CFBundleLocalizations') != list(configuration.localizations)):
        raise ValueError('Application localization metadata must match product configuration')
    verify_localizations(app / 'Contents/Resources' / RESOURCE_BUNDLE, configuration)
    for language in configuration.localizations:
        if not (app / 'Contents/Resources' / f'{language}.lproj/InfoPlist.strings').is_file():
            raise ValueError(f'Missing audio permission localization: {language}')
