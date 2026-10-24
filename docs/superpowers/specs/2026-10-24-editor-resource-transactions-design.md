# Editor resource transactions (advanced authoring PR 1)

## Problem and outcome

Today a workspace revision stores scene/project JSON, while resource files are
outside its history. New images use unique paths, but editing an existing MDL
or referenced script in place would change old revisions, break undo and allow
JSON and binary data to disagree after a failed save. This PR supplies coherent
revision ownership before any new skeletal or scripting UI ships.

## Revision model

Read existing schema-1 workspaces unchanged. Add a schema-2 workspace containing
the existing document fields plus a resource override map: a validated logical
project path maps to a content-addressed immutable resource blob owned by the
same workspace. Missing entries resolve to the original imported Project tree.
Scene entry, project.json and the source package are not resource-override
targets; scene/project data keep their existing explicit document fields.

Blob identity is SHA-256 of its bytes. Keep blobs in a private sibling resource
directory inside the workspace, outside the imported Project tree, so standard
project export never leaks internal metadata. Store only validated blob IDs in
the map, never arbitrary host paths. Validate blob existence and content when
accepting a revision, reopening it or exporting it. Two workspaces never gain
access to each other's blobs through an ID or path supplied by a browser.

New edits append blobs before publishing a reference. Existing resource bytes
are not overwritten. Unreferenced staged blobs are harmless private leftovers;
no automatic garbage collection is included because live undo entries may still
reference them. Disk failure is reported explicitly. This is a storage tradeoff,
not permission to treat an incomplete write as success.

Preserve schema 1 on a save that has never used overrides. A document which has
used schema 2 keeps it, including after its override map becomes empty. Newer
workspaces are rejected explicitly by older applications, as before. Do not
rewrite existing user workspaces on app startup or open.

## Public contracts and transport

Add a typed resource version/reference value and store operations to stage/read
workspace-owned immutable bytes. Extend document construction, serialization
and save with the override map while retaining existing call sites through an
empty default. Keep URL/path/symlink checks descriptor-relative, using the
existing file boundary. A blob read must verify the expected hash.

Extend the fixed Editor command/event protocol for resource staging and reads.
Requests/replies retain session, generation and request identity validation.
The host chooses workspace storage and blob paths; browser input never chooses
an arbitrary filesystem destination. Reject unknown fields and malformed
base64/IDs. Existing JSON-only documents and image addition keep working.

The browser document includes resource references in snapshots and equality.
Provide one transaction operation capable of committing related JSON changes
and a resource-reference change as one undo step. Validate before replacing the
current state. A failed operation leaves the document, undo and redo unchanged.
Staging bytes alone does not mark the project dirty until a reference is used.

## Save, preview and export

Save checks the previous revision under the existing workspace lock, verifies
every resource reference, then atomically replaces workspace.json. An error or
conflict leaves the old workspace readable with its old resource bytes. No
resource write occurs after publishing the document's reference. Save failure
does not clear dirty state or discard browser edits. Preserve freeze/thaw and
focused-input flushing.

The preview resource resolver uses the exact snapshot's override map. Pending
renders cannot observe a later revision's binary resource in place of their own.
Read the original Project file for paths not overridden. Unknown resources
remain intact. Failed preview reports the failure and retains editable data.

Loose export materializes the chosen saved revision's logical resources into
the existing staged export directory. Apply resource overrides before publishing
the destination. PKG export uses the same resolver and resource inventory,
including newly added logical paths, then performs the existing compatibility
readback. No blob directory or workspace lock/manifest is exported. Main receives
ordinary scene resources at their logical paths. Existing source package
exclusion and exclusive destination publication remain in force.

## Tests and acceptance

- Schema-1 read/save compatibility, schema-2 round trips, strict fields and IDs,
  resource paths, reserved targets and unknown original data preservation.
- Staging the same bytes yields the same identity; wrong/missing/corrupted blobs,
  symlinks, redirected roots and cross-workspace references fail visibly.
- One transaction changes JSON and binary references together; undo/redo restores
  both, no-op changes do not grow history, and failed transactions change neither.
- Save/reopen produces exactly the committed bytes. A revision conflict and a
  reproducible write failure leave the earlier revision and its resources valid.
- Preview resolves two revisions of the same logical resource independently.
  Native save acknowledgement retains consistent clean/dirty state.
- Author a small actual resource change, export loose and PKG, then verify its
  rendered pixels with Main's pinned runtime; reject tests that merely check a
  mocked success response. Verify newly added resource inventory and internal
  blob/metadata exclusion.
- Run existing focused Editor store/document/runtime/protocol/native acceptance
  and reproducible offline-resource checks. Record broader suite failures
  separately; do not report focused passes as an entire application-suite pass.

No timeline, rigging or IDE controls are exposed by this foundation PR. Their
user-facing specifications and tests belong to their respective roadmap steps.
