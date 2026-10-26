# Preview a scene with system audio response

In an independent **Run preview** window, enable **System audio response** to
send live stereo spectrum to the captured scene. This is a separate Editor
application setting, initially off. It does not enable audio capture in Dynamic
Wallpaper or install either app. Both apps use the same shared capture library
in their own processes.

System audio response requires macOS 14.2 or later. Editor's other features retain
macOS 14.0 support. On 14.0/14.1 the unavailable control explains the requirement;
there is no alternate screen-recording or microphone capture path.

## Turn it on explicitly

Only ready, playing snapshot previews subscribe. Merely opening or editing a
project does not capture audio. Enabling with no playing preview waits without
starting capture. When capture first starts, allow macOS system audio recording
for Editor if prompted. The native preview shows the current capture status.

All Editor preview windows share one capture owner and switch. Pausing or closing
one preview removes it from capture demand; another playing preview can continue.
Pausing/closing the last preview, disabling response or quitting Editor stops
capture and clears spectrum. Restart captures the same document revision in a
new scene page, with old-page callbacks retired before the new subscription.

The preview's **audio output remains muted**. Input spectrum is independent of
output volume. The edit canvas and model-import workbench still use zero spectrum
and never execute SceneScript. Exported loose/PKG projects retain the author's
normal audio-response code; live spectrum does not become saved project data.

## Understand what is captured

A private Core Audio stereo process tap excludes Editor's own process audio.
It uses no microphone or virtual loopback driver and does not change the system
output device. Samples are analyzed locally into 64 frequency bands per channel;
audio is not saved to files or uploaded. Main's separate capture excludes Main's
own process under its own setting and OS authorization.

If permission, device or capture cleanup fails, the native preview shows the
actual failure and offers explicit **Retry**. Ordinary scene animation continues
with cleared spectrum while capture is unavailable. There is no automatic retry,
simulated spectrum or hidden capture backend. Errors delivering data to a scene
page remain visible and remove that page from capture demand.

The independent snapshot retains source identity, runtime diagnostics and source
navigation. Changing this audio setting does not edit the captured project or
workspace history. See [snapshot preview](editor-scene-preview.md),
[Script API](editor-script-api.md) and [installation](editor-install.md).
