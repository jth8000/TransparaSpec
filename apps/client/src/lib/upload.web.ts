import type { ImagePickerAsset } from 'expo-image-picker';

import type { Schemas } from './api';

type Upload = Schemas['VideoUpload']['upload'];

/** Web: the picker gives us a File; send it straight to the provider. */
export async function uploadVideo(asset: ImagePickerAsset, upload: Upload): Promise<void> {
  if (!asset.file) throw new Error('No file selected');

  const form = new FormData();
  form.append(upload.form_field, asset.file, asset.file.name);

  const response = await fetch(upload.url, { method: upload.method, body: form });
  if (!response.ok) throw new Error(`Upload failed (${response.status})`);
}
