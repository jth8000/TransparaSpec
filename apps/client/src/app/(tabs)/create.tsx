import { useQueryClient } from '@tanstack/react-query';
import * as ImagePicker from 'expo-image-picker';
import { useCallback, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button, ErrorText, Field, Screen } from '@/components/ui';
import { api, ApiError, unwrap } from '@/lib/api';
import { useContentStatus, type ContentStatus } from '@/lib/socket';
import { uploadVideo } from '@/lib/upload';
import { colors, radius, space } from '@/theme';

type UploadState =
  | { step: 'idle' }
  | { step: 'uploading'; contentId?: string }
  | { step: 'processing'; contentId: string }
  | { step: 'ready' }
  | { step: 'failed'; message: string };

const STATUS_TEXT: Record<UploadState['step'], string> = {
  idle: '',
  uploading: 'Uploading…',
  processing: 'Processing your video…',
  ready: 'Your video is live.',
  failed: 'Upload failed.',
};

export default function Create() {
  const queryClient = useQueryClient();
  const [caption, setCaption] = useState('');
  const [upload, setUpload] = useState<UploadState>({ step: 'idle' });
  const [postBody, setPostBody] = useState('');
  const [posting, setPosting] = useState(false);
  const [postError, setPostError] = useState<string>();
  const [posted, setPosted] = useState(false);

  // Processing finishes asynchronously; the server pushes the result.
  const onStatus = useCallback(
    (status: ContentStatus) => {
      setUpload((current) => {
        if (current.step !== 'processing' || current.contentId !== status.content_id) return current;
        return status.status === 'ready'
          ? { step: 'ready' }
          : { step: 'failed', message: 'The video could not be processed (max 3 minutes).' };
      });
      if (status.status === 'ready') void queryClient.invalidateQueries({ queryKey: ['feed'] });
    },
    [queryClient],
  );
  useContentStatus(onStatus);

  const pickAndUpload = async () => {
    const picked = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: 'videos',
      videoMaxDuration: 180,
    });
    if (picked.canceled || !picked.assets[0]) return;

    setUpload({ step: 'uploading' });
    try {
      const slot = await unwrap(
        api.POST('/api/videos', { body: caption ? { caption } : {} }),
      );
      setUpload({ step: 'uploading', contentId: slot.content.id });
      await uploadVideo(picked.assets[0], slot.upload);
      setUpload({ step: 'processing', contentId: slot.content.id });
      setCaption('');
    } catch (e) {
      setUpload({ step: 'failed', message: e instanceof Error ? e.message : 'Upload failed' });
    }
  };

  const createPost = async () => {
    setPostError(undefined);
    setPosted(false);
    setPosting(true);
    try {
      await unwrap(api.POST('/api/posts', { body: { body: postBody } }));
      setPostBody('');
      setPosted(true);
      void queryClient.invalidateQueries({ queryKey: ['feed'] });
    } catch (e) {
      setPostError(e instanceof ApiError ? (e.fieldMessage('body') ?? e.message) : 'Could not post');
    } finally {
      setPosting(false);
    }
  };

  const busy = upload.step === 'uploading' || upload.step === 'processing';

  return (
    <Screen title="Create">
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Short video</Text>
        <Field
          label="Caption"
          testID="caption-input"
          value={caption}
          onChangeText={setCaption}
          placeholder="Say something about it"
          maxLength={2200}
        />
        <Button title="Choose a video" testID="pick-video" onPress={pickAndUpload} loading={busy} />
        {upload.step !== 'idle' && (
          <Text
            testID="upload-status"
            style={[styles.status, upload.step === 'ready' && styles.ok, upload.step === 'failed' && styles.bad]}>
            {upload.step === 'failed' ? upload.message : STATUS_TEXT[upload.step]}
          </Text>
        )}
      </View>

      <View style={styles.card}>
        <Text style={styles.cardTitle}>Text post</Text>
        <Field
          label="Post"
          testID="post-input"
          value={postBody}
          onChangeText={setPostBody}
          placeholder="What's on your mind?"
          multiline
          maxLength={2000}
        />
        <ErrorText>{postError}</ErrorText>
        {posted && <Text style={[styles.status, styles.ok]}>Posted.</Text>}
        <Button title="Post" testID="create-post" onPress={createPost} loading={posting} disabled={!postBody.trim()} />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: space.lg,
    gap: space.md,
    borderWidth: 1,
    borderColor: colors.border,
  },
  cardTitle: { color: colors.text, fontSize: 18, fontWeight: '700' },
  status: { color: colors.textMuted, fontSize: 14 },
  ok: { color: colors.success },
  bad: { color: colors.danger },
});
