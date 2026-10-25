#!/usr/bin/env python3
"""Real Editor browser/native/exports acceptance using isolated data and owned process groups."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'scripts'))
run_tests = runpy.run_path(str(root / 'scripts/test.py'))['run_tests']
run = root / '.build/verification/editor-native' / str(uuid.uuid4())
run.mkdir(parents=True)
app = run / 'EditorNativeTests.app'
frameworks = app / 'Contents/Frameworks'
product = json.loads(subprocess.check_output([sys.executable, str(root / 'scripts/product_configuration.py'), '--emit', 'shell-json'], text=True))
helper = product['application']['executable'] + ' Helper'
os.environ['EDITOR_TEST_ARTIFACTS'] = str(run / 'browser-export')
commands = [
    ('build', ['bash', str(root / 'scripts/build-editor-native-test.sh'), str(run)], 180),
    ('protocol', [str(run / 'protocol-tests')], 60),
    ('browser', ['node', str(root / 'Editor/Web/test-rendering.mjs')], 60),
    ('browser-image', ['node', str(root / 'Editor/Web/test-image-puppet.mjs')], 60),
    ('browser-rest', ['node', str(root / 'Editor/Web/test-model-rest.mjs')], 60),
    ('browser-gltf', ['node', str(root / 'Editor/Web/test-gltf-import.mjs')], 60),
    ('native', [str(app / 'Contents/MacOS/EditorNativeTests'),
                str(frameworks / 'Chromium Embedded Framework.framework'),
                str(frameworks / f'{helper}.app/Contents/MacOS' / helper), str(run / 'context'),
                str(root / 'Editor/Sources/EditorApp/Resources/EditorWeb'), str(root / 'Tests/Fixtures/SceneAnimatedLoose'),
                str(root / 'Sources/WallpaperApp/Resources/SceneRuntime'), str(run / 'browser-export/Loose'), str(run / 'browser-export/Package'),
                str(run / 'browser-export/ModelLoose'), str(run / 'browser-export/ModelPackage'),
                str(run / 'browser-export/ImageSource'), str(run / 'browser-export/ImageLoose'), str(run / 'browser-export/ImagePackage')], 60),
]
native = commands[-1][1]
brush_native = [native[0], '--brush-only', *native[1:]]
brush_native[4] = str(run / 'brush-context')
brush_native.extend([str(run / 'browser-export/BrushLoose'), str(run / 'browser-export/BrushPackage')])
commands.append(('native-brush', brush_native, 60))
rest_native = [native[0], '--rest-only', native[1], native[2], str(run / 'rest-context'), native[4],
               str(run / 'browser-export/RestSourceLoose'), native[6],
               str(run / 'browser-export/RestLoose'), str(run / 'browser-export/RestPackage')]
commands.append(('native-rest', rest_native, 60))
gltf_native = [native[0], '--gltf-only', native[1], native[2], str(run / 'gltf-context'), native[4],
               str(run / 'browser-export/GltfSource'), native[6],
               str(run / 'browser-export/GltfLoose'), str(run / 'browser-export/GltfPackage'),
               str(run / 'browser-export/gltf-source-command.json')]
commands.append(('native-gltf', gltf_native, 60))
print(f'EDITOR_NATIVE artifacts={run}', flush=True)
for name, command, budget in commands:
    print(f'EDITOR_NATIVE phase={name} budget={budget}s', flush=True)
    result = run_tests(command, timeout_seconds=budget, label=f'Editor {name}')
    if result:
        raise SystemExit(result)
print('EDITOR_NATIVE passed: browser, native child/keyboard/lifetime and Main export pixels', flush=True)
