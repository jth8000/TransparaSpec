import { useQueryClient } from '@tanstack/react-query';
import * as ImagePicker from 'expo-image-picker';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import { TopicPicker } from '@/components/topic-picker';
import { Button, ErrorText, Field, Screen } from '@/components/ui';
import { api, ApiError, unwrap } from '@/lib/api';
import { useContentStatus, type ContentStatus } from '@/lib/socket';
import { uploadVideo } from '@/lib/upload';
import { describeVideo, durationMs } from '@/lib/video-selection';
import { applyContentStatus, pendingContentId, uploadFinished, type UploadState } from '@/lib/upload-state';
import { colors, radius, space } from '@/theme';

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
  const [videoTopics, setVideoTopics] = useState<string[]>([]);
  // Picking a file only selects it; Post video uploads it, so the caption
  // and topics can be finished (and the pick changed) first.
  const [picked, setPicked] = useState<ImagePicker.ImagePickerAsset | null>(null);
  const [upload, setUpload] = useState<UploadState>({ step: 'idle' });
  const [postBody, setPostBody] = useState('');
  const [postTopics, setPostTopics] = useState<string[]>([]);
  const [posting, setPosting] = useState(false);
  const [postError, setPostError] = useState<string>();
  const [posted, setPosted] = useState(false);

  // Read by socket/async callbacks that may run after a re-render.
  const uploadRef = useRef(upload);
  useEffect(() => {
    uploadRef.current = upload;
  }, [upload]);

  // Processing finishes asynchronously and the server pushes the result.
  const onStatus = useCallback(
    (status: ContentStatus) => {
      setUpload((current) => applyContentStatus(current, status));
      if (status.status === 'ready') void queryClient.invalidateQueries({ queryKey: ['feed'] });
    },
    [queryClient],
  );

  // Pushed results aren't replayed, so ask the API directly whenever we may
  // have missed one: right after the upload, and on every channel (re)join.
  const reconcile = useCallback(
    async (contentId: string | undefined) => {
      if (!contentId) return;
      const { data } = await api.GET('/api/content/{id}', { params: { path: { id: contentId } } });
      if (data && (data.status === 'ready' || data.status === 'failed')) {
        onStatus({ content_id: data.id, status: data.status });
      }
    },
    [onStatus],
  );

  const onJoined = useCallback(() => void reconcile(pendingContentId(uploadRef.current)), [reconcile]);
  useContentStatus(onStatus, onJoined);

  const pickVideo = async () => {
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: 'videos',
      videoMaxDuration: 180,
    });
    if (result.canceled || !result.assets[0]) return;
    setPicked(result.assets[0]);
    // A new pick starts a new upload; drop the last one's status.
    setUpload({ step: 'idle' });
  };

  const postVideo = async () => {
    if (!picked) return;
    setUpload({ step: 'uploading' });
    try {
      const slot = await unwrap(
        api.POST('/api/videos', { body: { ...(caption ? { caption } : {}), topics: videoTopics } }),
      );
      setUpload({ step: 'uploading', contentId: slot.content.id });
      await uploadVideo(picked, slot.upload);
      setUpload((current) => uploadFinished(current, slot.content.id));
      setPicked(null);
      setCaption('');
      setVideoTopics([]);
      await reconcile(slot.content.id);
    } catch (e) {
      // Keep the pick so the user can try again.
      setUpload({ step: 'failed', message: e instanceof Error ? e.message : 'Upload failed' });
    }
  };

  const createPost = async () => {
    setPostError(undefined);
    setPosted(false);
    setPosting(true);
    try {
      await unwrap(api.POST('/api/posts', { body: { body: postBody, topics: postTopics } }));
      setPostBody('');
      setPostTopics([]);
      setPosted(true);
      void queryClient.invalidateQueries({ queryKey: ['feed'] });
    } catch (e) {
      setPostError(
        e instanceof ApiError
          ? (e.fieldMessage('body') ?? e.fieldMessage('topics') ?? e.message)
          : 'Could not post',
      );
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
        <TopicPicker value={videoTopics} onChange={setVideoTopics} testID="video-topics" />
        {picked && (
          <View style={styles.picked} testID="picked-video">
            <Text style={styles.pickedText} numberOfLines={1}>
              {describeVideo({ ...picked, duration: durationMs(picked.duration, Platform.OS) })}
            </Text>
            {!busy && (
              <Pressable onPress={() => setPicked(null)} accessibilityRole="button" testID="remove-video">
                <Text style={styles.remove}>Remove</Text>
              </Pressable>
            )}
          </View>
        )}
        <Button
          title={picked ? 'Change video' : 'Choose a video'}
          variant={picked ? 'secondary' : 'primary'}
          testID="pick-video"
          onPress={pickVideo}
          disabled={busy}
        />
        {picked && <Button title="Post video" testID="post-video" onPress={postVideo} loading={busy} />}
        {upload.step !== 'idle' && (
          <Text
            testID="upload-status"
            style={[
              styles.status,
              upload.step === 'ready' && styles.ok,
              upload.step === 'failed' && styles.bad,
            ]}>
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
        <TopicPicker value={postTopics} onChange={setPostTopics} testID="post-topics" />
        <ErrorText>{postError}</ErrorText>
        {posted && <Text style={[styles.status, styles.ok]}>Posted.</Text>}
        <Button
          title="Post"
          testID="create-post"
          onPress={createPost}
          loading={posting}
          disabled={!postBody.trim()}
        />
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
  picked: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
    padding: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.surfaceRaised,
  },
  pickedText: { flex: 1, color: colors.text, fontSize: 14 },
  remove: { color: colors.danger, fontSize: 13, fontWeight: '600' },
  status: { color: colors.textMuted, fontSize: 14 },
  ok: { color: colors.success },
  bad: { color: colors.danger },
});
