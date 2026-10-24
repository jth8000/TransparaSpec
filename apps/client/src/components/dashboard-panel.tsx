import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { api, unwrap } from '@/lib/api';
import { sourceLabel } from '@/lib/explanation';
import { useTopics } from '@/lib/topics';
import { colors, radius, space } from '@/theme';

// Categorical slots 1–5 of the reference palette, dark steps (the feed UI is
// always dark), in fixed order; validated on the #17171D surface (adjacent
// CVD ΔE ≥ 8.4, normal ≥ 19.3, all ≥ 3:1). Topics past five fold into Other.
const SERIES = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181'];
const OTHER = '#5c5c66';
// Diverging poles for signed totals: blue = pushed items up, red = held back.
const POSITIVE = '#3987e5';
const NEGATIVE = '#e66767';

const FEATURE_LABELS: Record<string, string> = {
  topic_affinity: 'learned interest',
  topic_preference: 'your setting',
  creator_affinity: 'creators you watch',
  following: 'accounts you follow',
  source_prior: 'source',
  freshness: 'recency',
  quality: 'completion rate',
  diversity: 'variety',
};

/**
 * The Algorithm Dashboard: what you were actually shown (topic mix) and
 * which parts of the ranking put it there (top drivers), summed from the
 * stored traces of shown items.
 */
export function DashboardPanel() {
  const [days, setDays] = useState<7 | 30>(7);
  const { data: taxonomy } = useTopics();
  const { data, isLoading } = useQuery({
    queryKey: ['dashboard', days],
    queryFn: () => unwrap(api.GET('/api/algorithm/dashboard', { params: { query: { days } } })),
  });

  const names = useMemo(() => new Map((taxonomy?.topics ?? []).map((t) => [t.slug, t.name])), [taxonomy]);
  const name = (slug: string) => names.get(slug) ?? slug;

  // The five most-shown topics get a slot (by total, ties by slug, so a
  // topic keeps its color while it stays in the top five); the rest are Other.
  const { colorOf, totals } = useMemo(() => {
    const totals = new Map<string, number>();
    for (const d of data?.topic_mix ?? [])
      for (const t of d.topics) totals.set(t.topic, (totals.get(t.topic) ?? 0) + t.count);
    const top = [...totals].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, SERIES.length);
    return { colorOf: new Map(top.map(([slug], i) => [slug, SERIES[i]])), totals };
  }, [data]);
  const otherTotal = [...totals].filter(([slug]) => !colorOf.has(slug)).reduce((s, [, n]) => s + n, 0);

  const maxDriver = Math.max(...(data?.top_drivers ?? []).map((d) => Math.abs(d.total)), 0.0001);

  return (
    <View style={styles.container}>
      <View style={styles.tabs}>
        {([7, 30] as const).map((d) => (
          <Pressable key={d} onPress={() => setDays(d)} style={[styles.tab, d === days && styles.tabOn]}>
            <Text style={[styles.tabText, d === days && styles.tabTextOn]}>{d} days</Text>
          </Pressable>
        ))}
      </View>

      {isLoading && <Text style={styles.muted}>Loading…</Text>}
      {data && data.shown === 0 && <Text style={styles.muted}>Nothing shown yet in this period.</Text>}

      {data && data.shown > 0 && (
        <>
          <Text style={styles.heading}>Topic mix of what you saw ({data.shown} items)</Text>
          {data.topic_mix.map((d) => {
            const total = d.topics.reduce((sum, t) => sum + t.count, 0);
            // Named topics in slot order, then Other as one segment.
            const segments = [
              ...[...colorOf].flatMap(([slug, color]) => {
                const count = d.topics.find((t) => t.topic === slug)?.count ?? 0;
                return count ? [{ key: slug, count, color }] : [];
              }),
              ...(() => {
                const other = d.topics
                  .filter((t) => !colorOf.has(t.topic))
                  .reduce((sum, t) => sum + t.count, 0);
                return other ? [{ key: 'other', count: other, color: OTHER }] : [];
              })(),
            ];
            return (
              <View
                key={d.date}
                style={styles.dayRow}
                accessible
                accessibilityLabel={`${d.date}: ${d.topics.map((t) => `${name(t.topic)} ${t.count}`).join(', ')}`}>
                <Text style={styles.day}>{d.date.slice(5)}</Text>
                <View style={styles.stack}>
                  {segments.map((seg, i) => (
                    <View
                      key={seg.key}
                      style={[
                        { flex: seg.count / total, backgroundColor: seg.color },
                        i === segments.length - 1 && styles.dataEnd,
                      ]}
                    />
                  ))}
                </View>
                <Text style={styles.dayTotal}>{total}</Text>
              </View>
            );
          })}
          <View style={styles.legend}>
            {[...colorOf].map(([slug, color]) => (
              <View key={slug} style={styles.legendItem}>
                <View style={[styles.swatch, { backgroundColor: color }]} />
                <Text style={styles.legendText}>
                  {name(slug)} {totals.get(slug)}
                </Text>
              </View>
            ))}
            {otherTotal > 0 && (
              <View style={styles.legendItem}>
                <View style={[styles.swatch, { backgroundColor: OTHER }]} />
                <Text style={styles.legendText}>Other {otherTotal}</Text>
              </View>
            )}
          </View>

          <Text style={styles.heading}>What drove it</Text>
          {data.top_drivers.map((d) => (
            <View key={`${d.feature}:${d.detail}`} style={styles.driver}>
              <Text style={styles.driverLabel} numberOfLines={1}>
                {FEATURE_LABELS[d.feature] ?? d.feature}
                {d.detail
                  ? ` · ${d.feature === 'source_prior' ? sourceLabel(d.detail) : name(d.detail)}`
                  : ''}
              </Text>
              <View style={styles.driverRow}>
                <View style={styles.driverTrack}>
                  <View
                    style={[
                      styles.driverBar,
                      {
                        width: `${(Math.abs(d.total) / maxDriver) * 100}%`,
                        backgroundColor: d.total < 0 ? NEGATIVE : POSITIVE,
                      },
                    ]}
                  />
                </View>
                <Text style={styles.driverValue}>
                  {d.total >= 0 ? '+' : '−'}
                  {Math.abs(d.total).toFixed(1)}
                </Text>
              </View>
            </View>
          ))}
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: space.sm },
  tabs: { flexDirection: 'row', gap: space.xs },
  tab: {
    paddingHorizontal: space.md,
    paddingVertical: space.xs,
    borderRadius: radius.pill,
    backgroundColor: colors.surfaceRaised,
  },
  tabOn: { backgroundColor: colors.accent },
  tabText: { color: colors.textMuted, fontWeight: '600' },
  tabTextOn: { color: colors.accentText },
  muted: { color: colors.textMuted, fontSize: 13 },
  heading: { color: colors.text, fontWeight: '700', marginTop: space.sm },
  dayRow: { flexDirection: 'row', alignItems: 'center', gap: space.sm },
  day: { color: colors.textMuted, fontSize: 12, width: 40, fontVariant: ['tabular-nums'] },
  // 2px surface gap between segments; square at the baseline, rounded data end.
  stack: { flex: 1, flexDirection: 'row', height: 14, gap: 2 },
  dataEnd: { borderTopRightRadius: 4, borderBottomRightRadius: 4 },
  dayTotal: {
    color: colors.textMuted,
    fontSize: 12,
    width: 24,
    textAlign: 'right',
    fontVariant: ['tabular-nums'],
  },
  legend: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  legendItem: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  swatch: { width: 10, height: 10, borderRadius: 2 },
  legendText: { color: colors.textMuted, fontSize: 12 },
  driver: { gap: 2 },
  driverLabel: { color: colors.text, fontSize: 13 },
  driverRow: { flexDirection: 'row', alignItems: 'center', gap: space.sm },
  driverTrack: { flex: 1, height: 8 },
  driverBar: { height: 8, borderTopRightRadius: 4, borderBottomRightRadius: 4 },
  driverValue: {
    color: colors.textMuted,
    fontSize: 12,
    width: 44,
    textAlign: 'right',
    fontVariant: ['tabular-nums'],
  },
});
