import type { ContentStatus } from './socket';

export type UploadState =
  | { step: 'idle' }
  | { step: 'uploading'; contentId?: string }
  | { step: 'processing'; contentId: string }
  | { step: 'ready' }
  | { step: 'failed'; message: string };

const FAILED_MESSAGE = 'The video could not be processed (max 3 minutes).';

/**
 * Applies a processing result for `content_id`. Accepted while still
 * `uploading` too: processing can finish before the upload request's
 * response reaches us, and a result must never be dropped.
 */
export function applyContentStatus(state: UploadState, status: ContentStatus): UploadState {
  const waiting = state.step === 'uploading' || state.step === 'processing';
  if (!waiting || state.contentId !== status.content_id) return state;

  return status.status === 'ready' ? { step: 'ready' } : { step: 'failed', message: FAILED_MESSAGE };
}

/**
 * The upload request finished: move to `processing` unless a result already
 * arrived (then keep it — don't regress `ready` back to `processing`).
 */
export function uploadFinished(state: UploadState, contentId: string): UploadState {
  return state.step === 'uploading' && state.contentId === contentId
    ? { step: 'processing', contentId }
    : state;
}

/** The content id whose result we're still waiting for, if any. */
export function pendingContentId(state: UploadState): string | undefined {
  return state.step === 'uploading' || state.step === 'processing' ? state.contentId : undefined;
}
