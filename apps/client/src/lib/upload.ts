import type { ImagePickerAsset } from 'expo-image-picker';

import type { Schemas } from './api';

type Upload = Schemas['VideoUpload']['upload'];

/**
 * Sends the picked file straight to the video provider's one-time URL
 * (never through our API). Native: React Native's FormData takes a file URI.
 */
export async function uploadVideo(asset: ImagePickerAsset, upload: Upload): Promise<void> {
  const form = new FormData();
  form.append(upload.form_field, {
    uri: asset.uri,
    name: asset.fileName ?? 'video.mp4',
    type: asset.mimeType ?? 'video/mp4',
  } as unknown as Blob);

  const response = await fetch(upload.url, { method: upload.method, body: form });
  if (!response.ok) throw new Error(`Upload failed (${response.status})`);
}
