# Editor resource collection design

Only immutable blobs in an Editor-owned project's `Resources` directory are eligible for collection. Original `Project` files, projects themselves, saved resource references, independent previews and handoffs are never collected by this feature. There are no history limits or age-based guesses.

## Ownership and locking

`EditorResourceSession` owns an OS shared `flock` on a project-local `.resource-session-lock`. Its descriptor is close-on-exec and is released only when the last strong reference dies. `acquireResourceSession(id:)` validates project identity before returning. Callers must retain their session across staging, all current/undo/redo/pending references, saving and asynchronous capture. `stageResource` requires the matching session explicitly; this prevents a successful stage call from returning an immediately collectible blob. A session is bound to the store directory and project identity.

Editor windows acquire a session before browser creation, retain it throughout authoring, and release only after `page.close` reports success and native resource tasks have drained. Failed closes retain the session. Operation-local shared sessions protect open/read/save/export APIs that are invoked without a window. Export sessions span actor suspension until copied resources are independently published or cleanup has completed.

Every cooperative operation takes locks in the same order: session shared lock, then `.workspace-lock` when manifest or resource inventory mutation requires it. Collection attempts the session lock exclusively and nonblocking; a busy project is reported as active and left untouched. It then obtains the workspace lock and re-reads the saved workspace, validates its identity, all saved resource bytes, and the complete resource inventory before unlinking anything. The OS releases locks after a crash, including abrupt process termination; no PID registry or timeout is used.

## Collection and filesystem safety

`collectUnusedResources(id:)` returns counts and reclaimed bytes or an active-session result. `collectUnusedResources()` enumerates only canonical UUID project directories under the store root and returns per-project results/errors; unrelated root entries are untouched. Missing Resources is a legitimate zero-blob project; malformed workspaces, invalid blob names, nested directories, symlinks, corrupt/missing saved references produce explicit validation failures and prevent deletion for that project. Removal IO failures surface explicitly; already removed unreferenced blobs stay removed.

Traversal and mutation use open directory descriptors, `O_NOFOLLOW`, `fstatat(AT_SYMLINK_NOFOLLOW)` and `unlinkat`. The collector pins the store, project and resource directories; it compares expected inode/device metadata before removal. A concurrent path replacement cannot redirect deletion outside the pinned directories. Locks are regular files and are never replaced or deleted by this implementation.

The application collects on launch, before opening a project, and after retiring its last editing window. Results are logged, and failures are presented through the existing error UI. Collection never runs while any process holds a resource session, so all open history versions remain protected without serializing browser history into native code.

## Acceptance

Tests exercise saved references versus abandoned versions, no deletion under one or multiple real process leases, crash recovery, session identity, concurrent stage/save/capture/close, malformed inventories, symlink/root redirection, and independent preview bytes after collection. Core checks run without GUI/CEF, with a cold build separated from the default 60-second runtime target.
