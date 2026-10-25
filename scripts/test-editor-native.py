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
    ('browser-clips', ['node', str(root / 'Editor/Web/test-model-clips.mjs')], 60),
    ('browser-poses', ['node', str(root / 'Editor/Web/test-model-poses.mjs')], 60),
    ('browser-mixing', ['node', str(root / 'Editor/Web/test-model-mixing.mjs')], 60),
    ('browser-events', ['node', str(root / 'Editor/Web/test-model-events.mjs')], 60),
    ('browser-fk', ['node', str(root / 'Editor/Web/test-model-fk.mjs')], 60),
    ('browser-ik', ['node', str(root / 'Editor/Web/test-model-ik.mjs')], 60),
    ('browser-keys', ['node', str(root / 'Editor/Web/test-model-keys.mjs')], 60),
    ('browser-script-migration', ['node', str(root / 'Editor/Web/test-script-migration.mjs')], 60),
    ('browser-script-contracts', ['node', str(root / 'Editor/Web/test-script-contracts.mjs')], 60),
    ('browser-script-language-runtime', ['node', str(root / 'Editor/Web/test-script-language-runtime.mjs')], 60),
    ('browser-code-tools', ['node', str(root / 'Editor/Web/test-code-tools.mjs')], 60),
    ('browser-script-workspace', ['node', str(root / 'Editor/Web/test-script-workspace.mjs')], 60),
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
clips_native = [native[0], '--clips-only', native[1], native[2], str(run / 'clips-context'), native[4],
                str(run / 'browser-export/ClipLoose'), native[6],
                str(run / 'browser-export/ClipLoose'), str(run / 'browser-export/ClipPackage'),
                str(run / 'browser-export/ClipStaticLoose'), str(run / 'browser-export/ClipStaticPackage')]
commands.append(('native-clips', clips_native, 60))
poses_native = [native[0], '--poses-only', native[1], native[2], str(run / 'poses-context'), native[4],
                str(run / 'browser-export/PoseLoose'), native[6],
                str(run / 'browser-export/PoseLoose'), str(run / 'browser-export/PosePackage')]
commands.append(('native-poses', poses_native, 60))
mixing_native = [native[0], '--mixing-only', native[1], native[2], str(run / 'mixing-context'), native[4],
                 str(run / 'browser-export/MixLoose'), native[6],
                 str(run / 'browser-export/MixLoose'), str(run / 'browser-export/MixPackage')]
commands.append(('native-mixing', mixing_native, 60))
events_native = [native[0], '--events-only', native[1], native[2], str(run / 'events-context'), native[4],
                 str(run / 'browser-export/EventsLoose'), native[6],
                 str(run / 'browser-export/EventsLoose'), str(run / 'browser-export/EventsPackage'),
                 str(run / 'browser-export/event-native-expected.mdl')]
commands.append(('native-events', events_native, 60))
fk_native = [native[0], '--fk-only', native[1], native[2], str(run / 'fk-context'), native[4],
             str(run / 'browser-export/FkLoose'), native[6],
             str(run / 'browser-export/FkLoose'), str(run / 'browser-export/FkPackage'),
             str(run / 'browser-export/fk-native-expected.mdl')]
commands.append(('native-fk', fk_native, 60))
ik_native = [native[0], '--ik-only', native[1], native[2], str(run / 'ik-context'), native[4],
             str(run / 'browser-export/IkSource'), native[6],
             str(run / 'browser-export/IkLoose'), str(run / 'browser-export/IkPackage'),
             str(run / 'browser-export/ik-native-expected.mdl')]
commands.append(('native-ik', ik_native, 60))
keys_native = [native[0], '--keys-only', native[1], native[2], str(run / 'keys-context'), native[4],
               str(run / 'browser-export/KeysSource'), native[6],
               str(run / 'browser-export/KeysLoose'), str(run / 'browser-export/KeysPackage'),
               str(run / 'browser-export/keys-native-expected.mdl')]
commands.append(('native-keys', keys_native, 60))
scripts_native = [native[0], '--scripts-only', native[1], native[2], str(run / 'script-contracts-context'), native[4],
                  str(run / 'browser-export/ScriptLoose'), native[6],
                  str(run / 'browser-export/ScriptLoose'), str(run / 'browser-export/ScriptPackage'),
                  str(run / 'browser-export/script-contract-source.json'), str(run / 'browser-export/script-contract-expected.json')]
commands.append(('native-script-contracts', scripts_native, 60))
preview_native = [native[0], '--preview-only', native[1], native[2], str(run / 'preview-context'), native[4],
                  str(run / 'browser-export/ScriptLoose'), str(root / 'Editor/Sources/EditorApp/Resources/ScenePreviewWeb')]
commands.append(('native-preview', preview_native, 60))
migration_native = [native[0], '--migration-only', native[1], native[2], str(run / 'migration-context'), native[4],
                    str(run / 'browser-export/MigrationLoose'), str(root / 'Editor/Sources/EditorApp/Resources/ScenePreviewWeb'),
                    native[6], str(run / 'browser-export/MigrationPackage'), str(run / 'browser-export/script-migration-document.json')]
commands.append(('native-script-migration', migration_native, 60))
workspace_native = [native[0], '--script-workspace-only', native[1], native[2], str(run / 'script-workspace-context'), native[4],
                    str(run / 'browser-export/ScriptWorkspaceLoose'), native[6],
                    str(run / 'browser-export/ScriptWorkspaceLoose'), str(run / 'browser-export/ScriptWorkspacePackage'),
                    str(run / 'browser-export/script-workspace-source.json'), str(run / 'browser-export/script-workspace-expected.json')]
commands.append(('native-script-workspace', workspace_native, 60))
code_tools_native = [native[0], '--code-tools-only', native[1], native[2], str(run / 'code-tools-context'), native[4],
                     str(run / 'browser-export/CodeToolsLoose'), native[6],
                     str(run / 'browser-export/CodeToolsLoose'), str(run / 'browser-export/CodeToolsPackage'),
                     str(run / 'browser-export/code-tools-source.json'), str(run / 'browser-export/code-tools-expected.json')]
commands.append(('native-code-tools', code_tools_native, 60))
print(f'EDITOR_NATIVE artifacts={run}', flush=True)
for name, command, budget in commands:
    print(f'EDITOR_NATIVE phase={name} budget={budget}s', flush=True)
    result = run_tests(command, timeout_seconds=budget, label=f'Editor {name}')
    if result:
        raise SystemExit(result)
print('EDITOR_NATIVE passed: browser, native child/keyboard/lifetime and Main export pixels', flush=True)
