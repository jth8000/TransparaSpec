import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { sourceMultiplier, topicControl, useAlgorithmSettings, useSettingsEditor } from '@/lib/algorithm';
import { api, unwrap } from '@/lib/api';
import { sourceLabel } from '@/lib/explanation';
import type { SettingsChange } from '@/lib/settings-batch';
import { useTopics } from '@/lib/topics';
import { colors, radius, space } from '@/theme';

import { TopicControl } from './topic-control';

type Props = {
  /** Topics to put first: the current item's, or one picked from "Why?". */
  focus: string[];
  /** Sends a change (over the feed channel, so the feed re-ranks live). */
  send: (change: SettingsChange) => Promise<unknown>;
  onClose: () => void;
};

/**
 * Live controls over the feed. Changes go out 150 ms after you stop moving
 * a slider; the feed behind re-ranks everything after the item you're on.
 */
export function TuneSheet({ focus, send, onClose }: Props) {
  const insets = useSafeAreaInsets();
  const { data: settings } = useAlgorithmSettings();
  const { data: taxonomy } = useTopics();
  const { data: interests } = useQuery({
    queryKey: ['interests'],
    queryFn: () => unwrap(api.GET('/api/me/interests')),
  });
  const { pending, change, error } = useSettingsEditor(send);
  const [showSources, setShowSources] = useState(false);

  const topics = useMemo(() => {
    const bySlug = new Map((taxonomy?.topics ?? []).map((t) => [t.slug, t]));
    const learned = (interests?.topics ?? []).filter((t) => t.score > 0).map((t) => t.slug);
    const boosted = (settings?.topics ?? []).map((t) => t.slug);
    const slugs = [...new Set([...focus, ...boosted, ...learned])].slice(0, 8);
    return slugs.flatMap((slug) => {
      const t = bySlug.get(slug);
      return t ? [t] : [];
    });
  }, [taxonomy, interests, settings, focus]);

  return (
    <View style={[styles.sheet, { paddingBottom: insets.bottom + space.md }]} testID="tune-sheet">
      <View style={styles.header}>
        <Text style={styles.title}>Tune your feed</Text>
        <Pressable onPress={onClose} accessibilityRole="button" testID="tune-close">
          <Text style={styles.done}>Done</Text>
        </Pressable>
      </View>
      <Text style={styles.hint}>
        Off hides posts labeled with that topic. Labels come from creators for now, so a mislabeled post can
        slip through.
      </Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      <ScrollView style={styles.scroll} contentContainerStyle={styles.list}>
        {topics.length === 0 && (
          <Text style={styles.hint}>Watch a few posts and their topics will show up here.</Text>
        )}
        {topics.map((t) => {
          const c = topicControl(settings, pending, t.slug, t.parent);
          return (
            <TopicControl
              key={t.slug}
              label={t.name}
              multiplier={c.multiplier}
              hardOff={c.hard_off}
              inherited={c.inherited}
              onChange={(ch) => change({ topics: { [t.slug]: ch } })}
              testID={`tune-topic-${t.slug}`}
            />
          );
        })}

        <Pressable onPress={() => setShowSources((s) => !s)} testID="tune-sources-toggle">
          <Text style={styles.section}>
            {showSources ? 'Where posts come from ▾' : 'Where posts come from ▸'}
          </Text>
        </Pressable>
        {showSources &&
          (settings?.available_sources ?? []).map((source) => (
            <TopicControl
              key={source}
              label={sourceLabel(source)}
              multiplier={sourceMultiplier(settings, pending, source)}
              onChange={(ch) =>
                ch.multiplier !== undefined && change({ sources: { [source]: ch.multiplier } })
              }
              testID={`tune-source-${source}`}
            />
          ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    maxHeight: '55%',
    backgroundColor: colors.surface,
    borderTopLeftRadius: radius.lg,
    borderTopRightRadius: radius.lg,
    borderTopWidth: 1,
    borderColor: colors.border,
    paddingHorizontal: space.lg,
    paddingTop: space.md,
    gap: space.sm,
  },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  title: { color: colors.text, fontSize: 18, fontWeight: '700' },
  done: { color: colors.accent, fontSize: 16, fontWeight: '700' },
  hint: { color: colors.textMuted, fontSize: 12 },
  error: { color: colors.danger, fontSize: 13 },
  scroll: { flexGrow: 0 },
  list: { gap: space.md, paddingBottom: space.md },
  section: { color: colors.accent, fontWeight: '600', marginTop: space.sm },
});
