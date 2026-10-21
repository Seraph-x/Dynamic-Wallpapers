#!/usr/bin/env python3
"""Create isolated local media, then run the prebuilt real Swift/CEF audio harness."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import runpy
import subprocess
import uuid


def write_fixture(project, source):
    """Keep each required browser audio source independently observable."""
    (project / 'icon.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="green"/></svg>')
    (project / 'index.html').write_text('''<!doctype html><meta charset="utf-8"><link rel="icon" href="icon.svg">
<style>html,body{margin:0;background:black}canvas{width:100vw;height:100vh}video,audio,iframe{display:none}</style>
<canvas id="canvas" width="64" height="64"></canvas><script src="main.js"></script>''')
    (project / 'main.js').write_text('const source=' + json.dumps(source) + ';\n' + '''
const canvas=document.getElementById('canvas'), gl=canvas.getContext('webgl');
if(!gl) throw new Error('WebGL unavailable');
const ready=[];
for(const kind of ['video','audio']) {
  if(source!=='all' && source!==kind) continue;
  const media=document.createElement(kind); media.src='video.webm'; media.loop=true; media.volume=.2;
  document.body.append(media); media.play().catch(e=>{throw e});
  media.onerror=()=>{throw new Error('Actual '+kind+' playback failed')};
  ready.push(()=>media.currentTime>.2 && (kind!=='video' || media.videoWidth>0));
}
if(source==='all' || source==='webaudio') {
  let running=false; ready.push(()=>running);
  setTimeout(()=>{
    const context=new AudioContext(), oscillator=context.createOscillator(), gain=context.createGain();
    oscillator.frequency.value=660; gain.gain.value=.04;
    oscillator.connect(gain).connect(context.destination); oscillator.start();
    const timer=setInterval(()=>{if(context.state==='running'){running=true;clearInterval(timer)}},20);
  },100);
}
if(source==='all' || source==='iframe') {
  let running=false; ready.push(()=>running);
  window.addEventListener('message', e=>{if(e.origin===location.origin && e.data==='child-running') running=true;});
  const child=document.createElement('iframe'); child.src='child.html'; document.body.append(child);
}
let everReady=false;
function paint(){everReady ||= ready.length>0 && ready.every(check=>check());
gl.clearColor(everReady?0:1,everReady?1:0,0,1);gl.clear(gl.COLOR_BUFFER_BIT);requestAnimationFrame(paint);} paint();''')
    (project / 'child.html').write_text('''<!doctype html><script>
const context=new AudioContext(), oscillator=context.createOscillator(), gain=context.createGain();
oscillator.frequency.value=880;gain.gain.value=.03;oscillator.connect(gain).connect(context.destination);oscillator.start();
const timer=setInterval(()=>{if(context.state==='running'){parent.postMessage('child-running',location.origin);clearInterval(timer)}},20);
</script>''')


def validate_evidence(run, *, pair=False):
    """Require durable, nonempty output evidence; Swift owns signal analysis."""
    def read(name):
        return json.loads((run / name).read_text())

    def nonempty_rows(value, name):
        if not isinstance(value, list) or not value or not all(isinstance(row, dict) for row in value):
            raise ValueError(f'{name}: expected nonempty object array')
        return value

    def finite(value):
        return type(value) in (int, float) and math.isfinite(value)

    for name in ('native-capture.json', 'default-capture.json'):
        capture = read(name)
        if (not isinstance(capture, dict) or capture.get('captureStoppedAndDrained') is not True
                or capture.get('errors') != []):
            raise ValueError(f'{name}: capture was not successfully stopped and drained')
        for packet in nonempty_rows(capture.get('packets'), name):
            if (not all(finite(packet.get(key)) for key in ('start', 'end', 'energy', 'samples'))
                    or packet['end'] <= packet['start'] or packet['energy'] < 0
                    or type(packet['samples']) is not int or packet['samples'] <= 0):
                raise ValueError(f'{name}: invalid raw capture packet')
    windows = nonempty_rows(read('windows.json'), 'windows.json')
    names = []
    for window in windows:
        if (not isinstance(window.get('name'), str) or not window['name']
                or not finite(window.get('start')) or not finite(window.get('end'))
                or window['end'] <= window['start'] or type(window.get('expectsSilence')) is not bool):
            raise ValueError('windows.json: invalid observation window')
        names.append(window['name'])
    if len(set(names)) != len(names):
        raise ValueError('windows.json: duplicate observation names')
    for filename, prefix in (('native-analysis.json', ''), ('default-analysis.json', 'default-')):
        reports = nonempty_rows(read(filename), filename)
        reported_names = []
        for report in reports:
            if (not isinstance(report.get('name'), str) or not finite(report.get('stableRMS'))
                    or report['stableRMS'] < 0 or type(report.get('stablePackets')) is not int
                    or report['stablePackets'] <= 0):
                raise ValueError(f'{filename}: invalid analysis report')
            reported_names.append(report['name'])
        if sorted(reported_names) != sorted(prefix + name for name in names):
            raise ValueError(f'{filename}: reports do not match observation windows')
    if pair:
        report = read('pair-analysis.json')
        if (not isinstance(report, dict)
                or not all(finite(report.get(key)) for key in ('mixEnergyRatio', 'fadeMiddleEnergyRatio', 'rampStart'))
                or report['mixEnergyRatio'] <= 0 or report['fadeMiddleEnergyRatio'] <= 0):
            raise ValueError('pair-analysis.json: missing or invalid two-page output analysis')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--source', choices=('all', 'video', 'audio', 'webaudio', 'iframe'), default='all')
    parser.add_argument('--pair', action='store_true', help='Exercise two independent webpages and their shared fade')
    options = parser.parse_args()
    if options.timeout <= 0:
        parser.error('timeout must be positive')
    if options.pair and options.source != 'all':
        parser.error('--pair defines its own two isolated sources; do not combine it with --source')
    root = Path(__file__).resolve().parent.parent
    app = root / '.build/dependencies/cef/WebAudioTests.app/Contents/MacOS/WebAudioTests'
    if not app.is_file():
        parser.error('Build first with scripts/build-web-audio-test.sh')
    run = root / '.build/verification/web-audio' / str(uuid.uuid4())
    project = run / 'project'
    project.mkdir(parents=True)
    ffmpeg = root / '.build/dependencies/ffmpeg/install/bin/ffmpeg'
    if not ffmpeg.is_file():
        raise FileNotFoundError(f'Pinned ffmpeg expected at {ffmpeg}; prepare the locked dependency')
    with (run / 'fixture.log').open('w') as log:
        subprocess.run([str(ffmpeg), '-v', 'error', '-i', str(root / '.build/dependencies/mpv/fixtures/vp9-opus.webm'),
                        '-map', '0:v:0', '-map', '0:a:0', '-c', 'copy', str(project / 'video.webm')],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    write_fixture(project, 'webaudio' if options.pair else options.source)
    arguments = [str(app), str(project)]
    if options.pair:
        peer = run / 'peer'; peer.mkdir()
        write_fixture(peer, 'iframe')
        arguments.append(str(peer))
    (run / 'fixture.json').write_text(json.dumps({'source': options.source, 'pair': options.pair, 'syntheticMedia': True}) + '\n')
    command = ['bash', '-c', 'output=$1; shift; exec "$@" > "$output" 2>&1', 'web-audio-tests', str(run / 'test.log'), *arguments]
    (run / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    status = 1
    print(f'WEB_AUDIO artifacts={run} source={options.source} execution_timeout={options.timeout}', flush=True)
    try:
        supervisor = runpy.run_path(str(root / 'scripts/test.py'))['run_tests']
        child_status = supervisor(command, timeout_seconds=options.timeout, label='Swift CEF audio integration')
        if child_status == 0:
            marker = ('WEB_AUDIO_PAIR PASS independent-sources=1 mixing=1 shared-fade=1 close-isolation=1 gates=1 '
                      'reload=1 shutdown=1 default-covered-samples=zero continuous=unverified physicalAcoustics=unverified') if options.pair else (
                      'WEB_AUDIO PASS webgl=1 fixture-progress=1 native-gain=1 gates=1 pause-close=1 '
                      'reload=1 shutdown=1 default-covered-samples=zero continuous=unverified physicalAcoustics=unverified')
            if marker not in (run / 'test.log').read_text():
                raise ValueError('Missing complete audio success result')
            validate_evidence(run, pair=options.pair)
        status = child_status
    finally:
        (run / 'result.json').write_text(json.dumps({'test_exit': status, 'execution_timeout': options.timeout,
            'executable_sha256': hashlib.sha256(app.read_bytes()).hexdigest()}, indent=2) + '\n')
    print(f'WEB_AUDIO test_exit={status}', flush=True)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
