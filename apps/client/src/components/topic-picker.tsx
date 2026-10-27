import { useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { filterTree, toggleTopic, topicTree, useTopics } from '@/lib/topics';
import { colors, radius, space } from '@/theme';

type Props = {
  value: string[];
  onChange: (slugs: string[]) => void;
  testID?: string;
};

/**
 * Lets a creator label their content with up to N taxonomy topics. Tier-1
 * topics expand to their tier-2 subtopics; either level can be picked. These
 * labels drive ranking and hard-off filtering, so the hint says so.
 */
export function TopicPicker({ value, onChange, testID }: Props) {
  const { data, isLoading } = useTopics();
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const [browsing, setBrowsing] = useState(false);

  const tree = useMemo(() => topicTree(data?.topics ?? []), [data]);
  const visible = useMemo(() => filterTree(tree, query), [tree, query]);
  const names = useMemo(() => new Map((data?.topics ?? []).map((t) => [t.slug, t.name])), [data]);
  const max = data?.max_creator_topics ?? 3;
  const searching = query.trim() !== '';

  const toggle = (slug: string) => onChange(toggleTopic(value, slug, max));

  return (
    <View style={styles.container} testID={testID}>
      <Text style={styles.label}>
        Topics ({value.length}/{max})
      </Text>
      <Text style={styles.hint}>
        Topics decide who sees this and let viewers filter it out, so pick what it&apos;s really about.
      </Text>

      {value.length > 0 && (
        <View style={styles.chips}>
          {value.map((slug) => (
            <Chip key={slug} label={`${names.get(slug) ?? slug}  ✕`} selected onPress={() => toggle(slug)} />
          ))}
        </View>
      )}

      <TextInput
        value={query}
        onChangeText={setQuery}
        placeholder={isLoading ? 'Loading topics…' : 'Search topics'}
        placeholderTextColor={colors.textMuted}
        style={styles.search}
        aria-label="Search topics"
        testID={testID && `${testID}-search`}
      />

      {!searching && (
        <Pressable onPress={() => setBrowsing((b) => !b)} testID={testID && `${testID}-browse`}>
          <Text style={styles.browse}>{browsing ? 'Hide topics ▾' : 'Browse topics ▸'}</Text>
        </Pressable>
      )}

      {(browsing || searching) && (
        <View style={styles.chips}>
          {visible.map(({ parent, children }) => {
            const expanded = searching || open === parent.slug;
            const picked = (slug: string) => value.includes(slug);
            const full = (slug: string) => !picked(slug) && value.length >= max;
            return (
              <View key={parent.slug} style={expanded ? styles.group : undefined}>
                <Chip
                  label={`${parent.name} ${expanded ? '▾' : '▸'}`}
                  selected={picked(parent.slug) || children.some((c) => picked(c.slug))}
                  onPress={() => setOpen(expanded && !searching ? null : parent.slug)}
                  testID={`topic-group-${parent.slug}`}
                />
                {expanded && (
                  <View style={styles.chips}>
                    <Chip
                      label={`All of ${parent.name}`}
                      small
                      selected={picked(parent.slug)}
                      disabled={full(parent.slug)}
                      onPress={() => toggle(parent.slug)}
                      testID={`topic-${parent.slug}`}
                    />
                    {children.map((child) => (
                      <Chip
                        key={child.slug}
                        label={child.name}
                        small
                        selected={picked(child.slug)}
                        disabled={full(child.slug)}
                        onPress={() => toggle(child.slug)}
                        testID={`topic-${child.slug}`}
                      />
                    ))}
                  </View>
                )}
              </View>
            );
          })}
          {searching && visible.length === 0 && <Text style={styles.hint}>No matching topics.</Text>}
        </View>
      )}
    </View>
  );
}

function Chip({
  label,
  selected,
  small,
  disabled,
  onPress,
  testID,
}: {
  label: string;
  selected?: boolean;
  small?: boolean;
  disabled?: boolean;
  onPress: () => void;
  testID?: string;
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityState={{ selected: !!selected, disabled: !!disabled }}
      testID={testID}
      style={[
        styles.chip,
        small && styles.chipSmall,
        selected && styles.chipOn,
        disabled && styles.chipDisabled,
      ]}>
      <Text style={[styles.chipText, small && styles.chipTextSmall, selected && styles.chipTextOn]}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: { gap: space.sm },
  label: { color: colors.text, fontWeight: '600', fontSize: 14 },
  hint: { color: colors.textMuted, fontSize: 12 },
  search: {
    color: colors.text,
    backgroundColor: colors.surfaceRaised,
    borderRadius: radius.md,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderWidth: 1,
    borderColor: colors.border,
  },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: space.xs + 2 },
  group: { width: '100%', gap: space.xs + 2 },
  browse: { color: colors.accent, fontWeight: '600', fontSize: 14 },
  chip: {
    alignSelf: 'flex-start',
    paddingHorizontal: space.md,
    paddingVertical: space.xs + 2,
    borderRadius: radius.pill,
    backgroundColor: colors.surfaceRaised,
    borderWidth: 1,
    borderColor: colors.border,
  },
  chipSmall: { paddingHorizontal: space.sm + 2, paddingVertical: space.xs },
  chipOn: { backgroundColor: colors.accent, borderColor: colors.accent },
  chipDisabled: { opacity: 0.4 },
  chipText: { color: colors.text, fontSize: 14 },
  chipTextSmall: { fontSize: 13 },
  chipTextOn: { color: colors.accentText, fontWeight: '600' },
});
