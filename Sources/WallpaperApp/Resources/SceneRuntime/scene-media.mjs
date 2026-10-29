const fields = ['hasMedia', 'state', 'title', 'artist', 'album', 'albumArtist', 'position', 'duration', 'thumbnail'];
const empty = () => ({ hasMedia: false, state: 0, title: '', artist: '', album: '', albumArtist: '', position: 0, duration: 0, thumbnail: null });

// Validate the wire representation here; the actual browser decoder reports
// image/decode/upload failures independently from valid metadata.
function validThumbnail(value) {
  if (value === null) return true;
  if (typeof value !== 'string' || !value.startsWith('data:image/png;base64,')) return false;
  const encoded = value.slice('data:image/png;base64,'.length);
  try {
    const bytes = atob(encoded);
    return btoa(bytes) === encoded && bytes.startsWith('\x89PNG\r\n\x1a\n');
  } catch { return false; }
}

export function validateMediaSnapshot(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== fields.length || !fields.every(key => Object.hasOwn(value, key)) ||
      typeof value.hasMedia !== 'boolean' || ![0, 1, 2].includes(value.state) ||
      !['title', 'artist', 'album', 'albumArtist'].every(key => typeof value[key] === 'string') ||
      !['position', 'duration'].every(key => typeof value[key] === 'number' && Number.isFinite(value[key]) && value[key] >= 0) ||
      !validThumbnail(value.thumbnail)) {
    throw new TypeError('Invalid system media snapshot');
  }
  if (!value.hasMedia && fields.some(key => value[key] !== empty()[key])) {
    throw new TypeError('Empty system media snapshot must clear every item field');
  }
  return value;
}

function project(value) {
  return {
    ...value, thumbnail: value.thumbnail ?? '', hasThumbnail: value.thumbnail !== null,
    // Public providers supply no palette or lyrics. These are explicit neutral
    // renderer values, never a guessed palette or synthetic lyric source.
    primaryColor: [0, 0, 0], secondaryColor: [0, 0, 0], tertiaryColor: [0, 0, 0],
    textColor: [1, 1, 1], highContrastColor: [1, 1, 1],
    trackIndex: 0, lyrics: [],
  };
}

export function createSceneMediaSource({ createMediaSource, report, onError, onArtworkError }) {
  let disposed = false;
  let revision = 0;
  let latest = empty(), failedThumbnail;
  const controls = Object.fromEntries(['play', 'pause', 'playPause', 'skipNext', 'skipPrevious'].map(command => [command, () => {
    if (disposed) throw new Error('System media source is disposed');
    if (!source.snapshot.hasMedia) throw new Error('No current system media item');
    const requestedRevision = revision;
    void Promise.resolve().then(() => {
      // A source switch/clear or disposal cancels an undispatched action. The
      // native owner also checks this token after the HTTP event arrives.
      if (disposed || revision !== requestedRevision) return;
      return report({ type: 'media-control', command, mediaRevision: requestedRevision });
    }).catch(onError);
  }]));
  const source = createMediaSource(project(empty()), controls);
  Object.defineProperty(source, 'mediaRevision', { get: () => revision });
  Object.defineProperty(source, 'onArtworkError', { value(error, thumbnail, failedRevision) {
    if (disposed || failedRevision !== revision || typeof thumbnail !== 'string' || latest.thumbnail !== thumbnail || failedThumbnail === thumbnail) return;
    failedThumbnail = thumbnail;
    source.set(project({ ...latest, thumbnail: null }));
    void Promise.resolve().then(() => {
      if (disposed || revision !== failedRevision) return;
      return onArtworkError(error, failedRevision);
    }).catch(onError);
  } });
  return Object.freeze({
    source,
    replace(value, mediaRevision) {
      if (disposed) throw new Error('System media source is disposed');
      if (!Number.isSafeInteger(mediaRevision) || mediaRevision <= 0) throw new TypeError('Invalid system media revision');
      const validated = validateMediaSnapshot(value);
      if (validated.thumbnail !== latest.thumbnail || mediaRevision !== revision) failedThumbnail = undefined;
      latest = { ...validated };
      source.set(project({ ...latest, thumbnail: latest.thumbnail === failedThumbnail ? null : latest.thumbnail }));
      revision = mediaRevision;
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      latest = empty(); failedThumbnail = undefined;
      source.set(project(latest));
    },
  });
}
