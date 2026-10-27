# Bind user properties to layer fields

**Text and font-size bindings are evaluated when the scene loads.** The pinned
renderer does not rebuild them from temporary live property changes. Edit the
project's saved default and open a new **Run preview** to verify those fields.
Visibility, opacity and RGB color bindings also react to live property changes.

## Connect a property

Create a definition and default in the [Project workspace](editor-property-definitions.md).
Select a layer and choose **Bind…** beside a supported inspector field. Select a
compatible property, review its default and the original field, then choose
**Apply binding**. The original literal/base value is retained in the scene.

| Layer field | Supported declaration |
|---|---|
| Visibility | Boolean, or choice with an explicit matching option. |
| Opacity | Number with a valid 0…1 default. |
| RGB color | Color. |
| Text | Text or compatible string-valued choices, on a text layer. |
| Font size | Number with a positive default, on a text layer. |

The dialog lists unavailable properties and their actual compatibility reasons.
Malformed fields retain their original JSON for inspection. Missing definitions,
unsupported current descriptors and conditions outside the declared choices are
reported; the Editor does not flatten or repair them silently.

The renderer matches text bindings against the original base's shape. A
numeric-looking original text such as `"123"` cannot initially resolve a
`textinput` declaration. This combination is unavailable with an explicit reason.
A text declaration whose default happens to contain numeric characters can bind
to a textual original base. Identifiers and condition values keep exact Unicode.

For choice-controlled visibility, select the option that should make the layer
visible. This writes the renderer's native condition form. Integer-shaped choice
values compare numerically: `"01"` and `"1"` compare equal. The dialog explains
this behavior rather than introducing a different comparison rule.

## Replace or remove a binding

The dialog displays the complete original field, including scripts and animation
data. Applying a new binding explicitly replaces this field's existing user,
script and animation controls. Other wrapper metadata is retained. **Undo**
restores the entire original field, including exact script bytes.

**Remove user binding** deletes only `user`. It restores the retained base and
keeps other metadata and remaining script/animation controls. Imported wrappers
without a valid base cannot be removed through this dialog, because there is no
known literal to restore; their raw data and reason remain visible.

An unresolved dialog blocks snapshot, save, export and history navigation until
applied or cancelled. Native freeze retains the unchanged canonical document and
reports unresolved work as dirty; subsequent snapshot/export requests fail with
the actual dialog error. Thaw and Cancel recover without content changes.

Binding edits use project Undo/Redo and persist through save/reopen and loose/PKG
export. Inspector edits and project-default changes remount the edit canvas, so
saved text/font-size bindings can be previewed there. Scripts remain disabled in
the authoring page and execute only in independent playback.

## Verification

```sh
node --test Editor/Web/property-bindings.test.mjs
node Editor/Web/build.mjs --check
python3 scripts/test-editor-native.py
```

The runner includes workbench authoring, an independent renderer contract test
and native CEF playback. It checks real pixels, numeric choice equality, text
shape compatibility, load-time text/font limits, removal restoration, modal
barriers and exact source preservation. Native store tests verify saved binding
data and reject a stale PKG that does not encode the changed scene.
