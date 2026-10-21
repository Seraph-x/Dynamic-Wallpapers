#!/usr/bin/env python3
"""Exercise real WebRuntime failure control flow with test-only CEF call injection."""
import json
import pathlib
import runpy
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
CEF = ROOT / '.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal'
WRAPPER = ROOT / '.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a'
BRIDGE = ROOT / 'Sources/WebWallpaperBridge'


def main():
    run = ROOT / '.build/verification/web-runtime-failures' / str(uuid.uuid4())
    run.mkdir(parents=True)
    print(f'WEB_RUNTIME_FAILURE artifacts={run}', flush=True)
    supervisor = runpy.run_path(str(ROOT / 'scripts/test.py'))['run_tests']
    executable = run / 'RuntimeFailureTests'
    runtime_object = run / 'WebRuntime.failure.o'
    common = ['clang++', '-std=c++20', '-mmacosx-version-min=14.0', '-fobjc-arc',
              '-frtti', '-O2', '-DNS_BLOCK_ASSERTIONS', '-Wall', '-Wextra', '-Werror',
              '-isystem', str(CEF), '-I', str(BRIDGE / 'include'), '-I', str(BRIDGE)]
    replacements = {
        'CefInitialize': 'DWTestCefInitialize',
        'CefShutdown': 'DWTestCefShutdown',
        'cef_unload_library': 'DWTestCefUnloadLibrary',
        'CefGetExitCode': 'DWTestCefGetExitCode',
        'CefDoMessageLoopWork': 'DWTestCefDoMessageLoopWork',
    }
    compile_runtime = [*common, *[f'-D{key}={value}' for key, value in replacements.items()],
                       '-c', str(BRIDGE / 'WebRuntime.mm'), '-o', str(runtime_object)]
    sources = ['WebPage.mm', 'WebClient.cpp', 'WebAudioOutput.mm', 'LocalProjectFiles.cpp', 'LocalWebRequestContext.cpp']
    link = [*common, str(ROOT / 'Tests/WebRuntimeHarness/runtime-failure-tests.mm'),
            str(runtime_object), *[str(BRIDGE / source) for source in sources], str(WRAPPER),
            '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'AVFoundation',
            '-framework', 'CoreAudio', '-o', str(executable)]
    cases = {mode: [str(executable), mode,
                    str(CEF / 'Release/Chromium Embedded Framework.framework'),
                    str(run / mode / 'cache')]
             for mode in ('init-failure', 'unload-failure', 'external-pump')}
    commands = {'compile_runtime': compile_runtime, 'link': link, **cases}
    (run / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    results = {}
    try:
        for label, command in (('compile_runtime', compile_runtime), ('link', link)):
            results[label] = supervisor(command, label=f'CEF runtime failure {label}')
            if results[label] != 0:
                return results[label]
        for mode, command in cases.items():
            (run / mode / 'cache').mkdir(parents=True)
            results[mode] = supervisor(command, label=f'CEF runtime {mode}')
        return next((status for status in results.values() if status != 0), 0)
    finally:
        (run / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f'WEB_RUNTIME_FAILURE results={results}; artifacts={run}', flush=True)


if __name__ == '__main__':
    sys.exit(main())
