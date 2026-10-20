import { fetch } from 'expo/fetch';
import { File } from 'expo-file-system';
import type { ImagePickerAsset } from 'expo-image-picker';

import type { Schemas } from './api';

type Upload = Schemas['VideoUpload']['upload'];

/**
 * Sends the picked file straight to the video provider's one-time URL
 * (never through our API). Native: expo-file-system's `File` is a Blob, so it
 * goes into FormData as-is (React Native's `{ uri, name, type }` parts aren't
 * supported by `expo/fetch`).
 */
export async function uploadVideo(asset: ImagePickerAsset, upload: Upload): Promise<void> {
  const form = new FormData();
  form.append(upload.form_field, new File(asset.uri), asset.fileName ?? 'video.mp4');

  const response = await fetch(upload.url, { method: upload.method, body: form });
  if (!response.ok) throw new Error(`Upload failed (${response.status})`);
}
