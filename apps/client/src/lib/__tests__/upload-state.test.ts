import { applyContentStatus, pendingContentId, uploadFinished, type UploadState } from '../upload-state';

const ID = 'content-1';

describe('upload state', () => {
  it('ready during processing → ready', () => {
    const state: UploadState = { step: 'processing', contentId: ID };
    expect(applyContentStatus(state, { content_id: ID, status: 'ready' })).toEqual({ step: 'ready' });
  });

  it('a result that beats the upload response is kept (the race)', () => {
    let state: UploadState = { step: 'uploading', contentId: ID };
    state = applyContentStatus(state, { content_id: ID, status: 'ready' });
    state = uploadFinished(state, ID);

    expect(state).toEqual({ step: 'ready' });
  });

  it('normal order: upload finishes, then the result arrives', () => {
    let state: UploadState = { step: 'uploading', contentId: ID };
    state = uploadFinished(state, ID);
    expect(state).toEqual({ step: 'processing', contentId: ID });

    state = applyContentStatus(state, { content_id: ID, status: 'failed' });
    expect(state.step).toBe('failed');
  });

  it('ignores results for other uploads and when not waiting', () => {
    const processing: UploadState = { step: 'processing', contentId: ID };
    expect(applyContentStatus(processing, { content_id: 'other', status: 'ready' })).toBe(processing);

    const idle: UploadState = { step: 'idle' };
    expect(applyContentStatus(idle, { content_id: ID, status: 'ready' })).toBe(idle);
  });

  it('reports which upload is still pending', () => {
    expect(pendingContentId({ step: 'uploading' })).toBeUndefined();
    expect(pendingContentId({ step: 'uploading', contentId: ID })).toBe(ID);
    expect(pendingContentId({ step: 'processing', contentId: ID })).toBe(ID);
    expect(pendingContentId({ step: 'ready' })).toBeUndefined();
  });
});
