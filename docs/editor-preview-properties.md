# Test scene user properties

An independent **Run preview** window can test existing property values without
editing the project. Values belong to that preview only; they are not saved,
added to Undo history or included in loose/PKG exports. **Restart from beginning**
restores captured defaults in a fresh page.

## Change a value

Open a snapshot of a project with declarations in
`project.json` → `general.properties`. In **User properties**, commit an edited
field or choose **Apply**. The host validates before sending the change to the
running scene. Invalid input stays visible without changing the acknowledged
value. **Reset** sends captured defaults through the same real command path.

| Declaration | Value | Validation |
|---|---|---|
| `bool` | Checkbox | Boolean, without converting numbers or text. |
| `slider` | Number | Finite, within any declared bounds; no invented limits or clamping. |
| `color` | RGB | Three finite components in 0…1, stored as the project's `"r g b"` string. |
| `textinput` | Text | Exact text, including empty strings and Unicode. |
| `combo` | Declared option | Exact string value from the captured options. |

Each window uses its captured declarations, not newer workbench edits. Author
text and the stable property name identify each row. Unknown types, malformed
declarations, unsupported conditions, file/directory inputs and preset-only
values remain visible with a specific read-only reason. General declarations
override matching preset entries, as in the pinned engine. Definitions and
unknown metadata are never rewritten or silently converted.

If the property metadata cannot be inspected, this section displays the actual
inspection error and disables its inputs. It does not call the project empty or
stop ordinary preview playback, pause, restart or close. Exact Unicode names and
option values retain their individual identities.

This panel tests values; it does not author property definitions. Main's ordinary
wallpaper playback still uses authored defaults and has no persisted override UI.
System-media integration remains unavailable.

## Observe the scene

The engine dispatches initial values and later changed values to
`applyUserProperties(properties)`. Values are unwrapped; colors are Vec3 values.
`engine.userProperties` reflects the current table. Scripts and existing bindings
determine the resulting scene. The IDE starter records delivered keys without
inventing a project property name.

Playing previews update in place. Paused previews render accepted changes without
resuming or seeking the clock. Acknowledgement covers value acceptance and the
requested Editor rendering frame; it does not promise completion of all
internally asynchronous asset work in the pin. Script warnings and failures stay
visible in [diagnostics](editor-script-diagnostics.md).

The serialized, generation-bound command carries data only. Editor controls stay
private to the preview wrapper, with no workbench session or native project-write
channel. Closing/restarting retires old acknowledgements; actual page release
still precedes snapshot cleanup. See [snapshot ownership](editor-scene-preview.md)
and the [Script API](editor-script-api.md).
