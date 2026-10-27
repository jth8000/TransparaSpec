import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { api, unwrap } from '@/lib/api';
import { colors, radius, space } from '@/theme';

/**
 * What the algorithm has learned about you: each topic interest, how strong
 * it is, the views it came from, and a way to make it forget.
 */
export function InterestsPanel() {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState<string | null>(null);
  const { data, isLoading } = useQuery({
    queryKey: ['interests'],
    queryFn: () => unwrap(api.GET('/api/me/interests')),
  });

  const forget = useMutation({
    mutationFn: (slug: string) =>
      unwrap(api.DELETE('/api/me/interests/topics/{slug}', { params: { path: { slug } } })),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['interests'] }),
  });

  if (isLoading) return <Text style={styles.muted}>Loading…</Text>;
  const topics = data?.topics ?? [];
  if (topics.length === 0) {
    return <Text style={styles.muted}>Nothing learned yet. Watch a few things in For You.</Text>;
  }

  return (
    <View style={styles.list}>
      {topics.slice(0, 15).map((t) => (
        <View key={t.slug} style={styles.item} testID={`interest-${t.slug}`}>
          <Pressable style={styles.row} onPress={() => setOpen(open === t.slug ? null : t.slug)}>
            <View style={styles.rowText}>
              <Text style={styles.name}>{t.name}</Text>
              <Text style={styles.muted}>
                from {t.evidence_count} {t.evidence_count === 1 ? 'view' : 'views'} · fades unless renewed
              </Text>
            </View>
            <View style={styles.meter}>
              <View
                style={[
                  styles.meterFill,
                  { width: `${Math.min(Math.abs(t.value), 1) * 100}%` },
                  t.value < 0 && styles.negative,
                ]}
              />
            </View>
          </Pressable>
          {open === t.slug && (
            <Evidence slug={t.slug} onForget={() => forget.mutate(t.slug)} forgetting={forget.isPending} />
          )}
        </View>
      ))}
    </View>
  );
}

function Evidence({
  slug,
  onForget,
  forgetting,
}: {
  slug: string;
  onForget: () => void;
  forgetting: boolean;
}) {
  const { data } = useQuery({
    queryKey: ['interest-evidence', slug],
    queryFn: () =>
      unwrap(api.GET('/api/me/interests/topics/{slug}/evidence', { params: { path: { slug } } })),
  });

  return (
    <View style={styles.evidence}>
      {(data?.views ?? []).slice(0, 5).map((v, i) => (
        <Text key={i} style={styles.evidenceLine} numberOfLines={1}>
          {v.delta >= 0 ? '+' : '−'}
          {Math.abs(v.delta).toFixed(2)} · {v.completed ? 'watched to the end' : 'watched part'} ·{' '}
          {v.item
            ? `@${v.item.author.handle}${v.item.caption ? ` “${v.item.caption}”` : ''}`
            : 'removed post'}
        </Text>
      ))}
      <Pressable onPress={onForget} disabled={forgetting} testID={`forget-${slug}`}>
        <Text style={styles.forget}>{forgetting ? 'Forgetting…' : 'Forget this interest'}</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  list: { gap: space.sm },
  item: { gap: space.xs },
  row: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  rowText: { flex: 1 },
  name: { color: colors.text, fontSize: 15, fontWeight: '600' },
  muted: { color: colors.textMuted, fontSize: 12 },
  meter: { width: 80, height: 6, borderRadius: radius.pill, backgroundColor: colors.surfaceRaised },
  // Diverging poles (dashboard palette): blue = learned like, red = learned dislike.
  meterFill: { height: 6, borderTopRightRadius: 3, borderBottomRightRadius: 3, backgroundColor: '#3987e5' },
  negative: { backgroundColor: '#e66767' },
  evidence: { paddingLeft: space.md, gap: 2 },
  evidenceLine: { color: colors.textMuted, fontSize: 12 },
  forget: { color: colors.danger, fontSize: 13, fontWeight: '600', marginTop: space.xs },
});
