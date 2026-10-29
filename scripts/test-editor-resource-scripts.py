#!/usr/bin/env python3
"""Exercise actual resource Script authoring, immutable exports and native playback."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent
run = root / '.build/verification/editor-resource-scripts' / str(uuid.uuid4())
run.mkdir(parents=True)
app = run / 'EditorNativeTests.app'
frameworks = app / 'Contents/Frameworks'
product = json.loads(subprocess.check_output(
    [sys.executable, str(root / 'scripts/product_configuration.py'), '--emit', 'shell-json'], text=True))
helper = product['application']['executable'] + ' Helper'
artifacts = run / 'browser-export'
os.environ['EDITOR_TEST_ARTIFACTS'] = str(artifacts)
commands = [
    ('build', ['bash', str(root / 'scripts/build-editor-native-test.sh'), str(run)], 180),
    ('protocol', [str(run / 'protocol-tests')], 60),
    ('scene-protocol', [str(run / 'scene-protocol-tests')], 60),
    ('browser', ['node', str(root / 'Editor/Web/test-resource-script-workspace.mjs')], 60),
]
for sink in ['effect', 'child-override', 'emitter-rate']:
    commands.append((sink, [
        str(app / 'Contents/MacOS/EditorNativeTests'), '--resource-scripts-only',
        str(frameworks / 'Chromium Embedded Framework.framework'),
        str(frameworks / f'{helper}.app/Contents/MacOS' / helper), str(run / (sink + '-context')),
        str(root / 'Editor/Sources/EditorApp/Resources/EditorWeb'), str(artifacts / 'ResourceScripts' / sink),
        str(root / 'Editor/Sources/EditorApp/Resources/ScenePreviewWeb'),
        str(root / 'Sources/WallpaperApp/Resources/SceneRuntime'),
    ], 60))
    commands.append((sink + '-export-bytes', ['node', str(root / 'scripts/verify-editor-resource-script-export.mjs'),
        str(artifacts / 'ResourceScripts' / sink), str(run / (sink + '-context'))], 60))
supervise = runpy.run_path(str(root / 'scripts/test.py'))['run_tests']
print(f'EDITOR_RESOURCE_SCRIPTS artifacts={run}', flush=True)
for name, command, budget in commands:
    print(f'EDITOR_RESOURCE_SCRIPTS phase={name} budget={budget}s', flush=True)
    status = supervise(command, timeout_seconds=budget, label=f'Editor resource Script {name}')
    if status:
        raise SystemExit(status)
print('EDITOR_RESOURCE_SCRIPTS passed', flush=True)
