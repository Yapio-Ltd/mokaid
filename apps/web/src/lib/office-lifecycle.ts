// Auth/account must not import the renderer just to dispose a scene that was
// never created. The optional web experience registers only after it is loaded.
let disposeLoadedOffice: (() => void) | undefined;

export function registerOfficeCleanup(dispose: () => void): () => void {
  disposeLoadedOffice = dispose;
  return () => {
    if (disposeLoadedOffice === dispose) disposeLoadedOffice = undefined;
  };
}

export function disposeOfficeIfLoaded(): void {
  disposeLoadedOffice?.();
}
