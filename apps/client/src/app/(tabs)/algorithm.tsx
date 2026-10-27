import { useQueryClient } from '@tanstack/react-query';
import { useCallback, useMemo, useState } from 'react';
import { useFocusEffect } from 'expo-router';
import { Pressable, StyleSheet, Switch, Text, TextInput, View } from 'react-native';

import { DashboardPanel } from '@/components/dashboard-panel';
import { InterestsPanel } from '@/components/interests-panel';
import { TopicControl } from '@/components/topic-control';
import { Button, ErrorText, Screen } from '@/components/ui';
import {
  saveSettings,
  SETTINGS_KEY,
  sourceMultiplier,
  topicControl,
  useAlgorithmSettings,
  useSettingsEditor,
} from '@/lib/algorithm';
import { api, unwrap } from '@/lib/api';
import { useFlushEvents } from '@/lib/events';
import { sourceLabel } from '@/lib/explanation';
import { filterTree, topicTree, useTopics } from '@/lib/topics';
import { colors, radius, space } from '@/theme';

/**
 * Everything about your algorithm in one place: personalization, every
 * topic and source control, what it has learned about you, and what it has
 * been showing you. Changes apply to open feeds live.
 */
export default function AlgorithmScreen() {
  const queryClient = useQueryClient();
  const flushEvents = useFlushEvents();
  const { data: settings } = useAlgorithmSettings();
  const { data: taxonomy } = useTopics();
  const { pending, change, error, supersede } = useSettingsEditor(saveSettings);
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const [browsing, setBrowsing] = useState(false);
  const [modeError, setModeError] = useState<string>();
  const [switching, setSwitching] = useState(false);

  const searching = query.trim() !== '';
  // Tabs stay mounted, so refresh what may have changed while you were in
  // the feed (learned interests, what you were shown, settings from Tune).
  useFocusEffect(
    useCallback(() => {
      for (const queryKey of [['interests'], ['dashboard'], SETTINGS_KEY]) {
        void queryClient.invalidateQueries({ queryKey });
      }
    }, [queryClient]),
  );

  const tree = useMemo(() => filterTree(topicTree(taxonomy?.topics ?? []), query), [taxonomy, query]);
  const bySlug = useMemo(() => new Map((taxonomy?.topics ?? []).map((t) => [t.slug, t])), [taxonomy]);
  const adjusted = (settings?.topics ?? []).flatMap((t) => {
    const topic = bySlug.get(t.slug);
    return topic ? [topic] : [];
  });
  const personalized = !(settings?.non_personalized ?? false);

  // Queued events reach the server before the mode changes, so they're
  // learned (or not) under the mode they were watched in (ADR 0012).
  const setPersonalized = async (on: boolean) => {
    setSwitching(true);
    setModeError(undefined);
    try {
      if (!(await flushEvents())) throw new Error('Couldn’t sync recent activity. Check your connection.');
      await saveSettings({ non_personalized: !on });
      await queryClient.invalidateQueries({ queryKey: SETTINGS_KEY });
    } catch (e) {
      setModeError(e instanceof Error ? e.message : 'Could not change this');
    } finally {
      setSwitching(false);
    }
  };

  // A reset overrides every edit before it, so it goes through the same
  // write sequence: no queued or in-flight slider save can land after it.
  const reset = () => supersede(() => unwrap(api.POST('/api/algorithm/settings/reset')));

  return (
    <Screen title="Your algorithm">
      <Section title="Personalized feed">
        <View style={styles.modeRow}>
          <Text style={styles.body}>
            {personalized
              ? 'On: For You uses what you watch to learn your interests.'
              : 'Off: For You uses only accounts you follow, trending and new posts, plus your own settings. What you watch doesn’t build your interest profile or feed “people like you” recommendations. It still counts toward anonymous totals like trending and completion rates, which shape what everyone sees.'}
          </Text>
          <Switch
            value={personalized}
            disabled={switching || !settings}
            onValueChange={(on) => void setPersonalized(on)}
            accessibilityLabel="Personalized feed"
            testID="personalized-switch"
          />
        </View>
        <ErrorText>{modeError}</ErrorText>
      </Section>

      <Section title="What it has learned about you">
        <InterestsPanel />
      </Section>

      <Section title="What you’ve been shown">
        <DashboardPanel />
      </Section>

      <Section title="Topics">
        <Text style={styles.hint}>
          Slide right for more, left for less; switch off to hide posts labeled with the topic (labels come
          from creators for now). Subtopics follow their category unless you set them.
        </Text>
        <TextInput
          value={query}
          onChangeText={setQuery}
          placeholder="Search topics"
          placeholderTextColor={colors.textMuted}
          style={styles.search}
          aria-label="Search topics"
        />
        {!searching && !browsing && adjusted.length === 0 && (
          <Text style={styles.hint}>Every topic is at its default.</Text>
        )}
        {!searching &&
          !browsing &&
          adjusted.map((t) => {
            const c = topicControl(settings, pending, t.slug, t.parent);
            return (
              <TopicControl
                key={t.slug}
                label={t.name}
                multiplier={c.multiplier}
                hardOff={c.hard_off}
                onChange={(ch) => change({ topics: { [t.slug]: ch } })}
                testID={`algo-topic-${t.slug}`}
              />
            );
          })}
        {!searching && (
          <Pressable onPress={() => setBrowsing((b) => !b)} testID="browse-topics">
            <Text style={styles.expand}>
              {browsing ? 'Show only adjusted topics ▾' : 'Browse all topics ▸'}
            </Text>
          </Pressable>
        )}
        {(browsing || searching) &&
          tree.map(({ parent, children }) => {
            const expanded = searching || open === parent.slug;
            const c = topicControl(settings, pending, parent.slug);
            return (
              <View key={parent.slug} style={styles.group}>
                <TopicControl
                  label={parent.name}
                  multiplier={c.multiplier}
                  hardOff={c.hard_off}
                  onChange={(ch) => change({ topics: { [parent.slug]: ch } })}
                  testID={`algo-topic-${parent.slug}`}
                />
                {children.length > 0 && (
                  <Pressable onPress={() => setOpen(expanded && !searching ? null : parent.slug)}>
                    <Text style={styles.expand}>
                      {expanded ? 'Hide subtopics ▾' : `${children.length} subtopics ▸`}
                    </Text>
                  </Pressable>
                )}
                {expanded &&
                  children.map((child) => {
                    const cc = topicControl(settings, pending, child.slug, parent.slug);
                    return (
                      <View key={child.slug} style={styles.child}>
                        <TopicControl
                          label={child.name}
                          multiplier={cc.multiplier}
                          hardOff={cc.hard_off}
                          inherited={cc.inherited}
                          onChange={(ch) => change({ topics: { [child.slug]: ch } })}
                          testID={`algo-topic-${child.slug}`}
                        />
                      </View>
                    );
                  })}
              </View>
            );
          })}
        <ErrorText>{error}</ErrorText>
      </Section>

      <Section title="Where posts come from">
        {(settings?.available_sources ?? []).map((source) => (
          <TopicControl
            key={source}
            label={sourceLabel(source)}
            multiplier={sourceMultiplier(settings, pending, source)}
            onChange={(ch) => ch.multiplier !== undefined && change({ sources: { [source]: ch.multiplier } })}
            testID={`algo-source-${source}`}
          />
        ))}
        <Button title="Reset topics and sources" variant="secondary" onPress={() => void reset()} />
      </Section>
    </Screen>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={styles.card}>
      <Text style={styles.cardTitle}>{title}</Text>
      {children}
    </View>
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
  body: { flex: 1, color: colors.text, fontSize: 14 },
  hint: { color: colors.textMuted, fontSize: 12 },
  modeRow: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  search: {
    color: colors.text,
    backgroundColor: colors.surfaceRaised,
    borderRadius: radius.md,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderWidth: 1,
    borderColor: colors.border,
  },
  group: { gap: space.xs, paddingBottom: space.sm, borderBottomWidth: 1, borderColor: colors.border },
  child: { paddingLeft: space.lg },
  expand: { color: colors.accent, fontSize: 13, fontWeight: '600' },
});
