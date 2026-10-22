import { Pressable, StyleSheet, Text, View } from 'react-native';

import {
  explanationRows,
  explanationTotal,
  labelSources,
  sourceLabel,
  type Explanation as ExplanationData,
} from '@/lib/explanation';
import { colors, radius, space } from '@/theme';

type Props = {
  explanation: ExplanationData;
  /** Opens the Tune controls for a topic (or with no topic, for sources). */
  onAdjust?: (topic?: string) => void;
};

const signed = (n: number) => `${n >= 0 ? '+' : '−'}${Math.abs(n).toFixed(2)}`;

/**
 * "Why am I seeing this?", from the trace stored when the item was served
 * (ADR 0006): one row per contribution, largest effect first, adding up to
 * the item's score. Nothing here is recomputed.
 */
export function Explanation({ explanation: e, onAdjust }: Props) {
  const rows = explanationRows(e);
  const max = Math.max(...rows.map((r) => Math.abs(r.contribution)), 0.0001);
  const labels = labelSources(e);

  return (
    <View style={styles.container} testID="explanation">
      <Text style={styles.lead}>
        Found via <Text style={styles.strong}>{sourceLabel(e.candidate_source)}</Text>
        {e.sources.length > 1
          ? ` (also ${e.sources
              .filter((s) => s !== e.candidate_source)
              .map(sourceLabel)
              .join(', ')})`
          : ''}
        .
      </Text>

      <View style={styles.rows}>
        {rows.map((r) => (
          <View key={r.key} style={styles.row} testID="why-row">
            <View style={styles.rowText}>
              <Text style={styles.label}>{r.label}</Text>
              <Text style={styles.detail}>{r.detail}</Text>
              <View style={styles.barTrack}>
                <View
                  style={[
                    styles.bar,
                    { width: `${(Math.abs(r.contribution) / max) * 100}%` },
                    r.contribution < 0 && styles.barNegative,
                  ]}
                />
              </View>
            </View>
            <View style={styles.rowRight}>
              <Text
                style={[styles.amount, r.contribution < 0 && styles.negative]}
                testID="why-row-contribution">
                {signed(r.contribution)}
              </Text>
              {onAdjust && (r.topic || r.source) ? (
                <Pressable
                  onPress={() => onAdjust(r.topic)}
                  accessibilityRole="button"
                  testID={r.topic ? `why-adjust-${r.topic}` : 'why-adjust-sources'}>
                  <Text style={styles.adjust}>Adjust</Text>
                </Pressable>
              ) : null}
            </View>
          </View>
        ))}
      </View>

      <View style={styles.total}>
        <Text style={styles.totalLabel}>Score</Text>
        <Text style={styles.totalValue} testID="why-total">
          {explanationTotal(e).toFixed(3)}
        </Text>
      </View>

      {labels.map((l) => (
        <Text key={l.topic} style={styles.footnote}>
          “{l.topic}” label from: {l.sources.join(', ')}
        </Text>
      ))}
      <Text style={styles.footnote}>
        Ranked by {e.ranker_version} with your settings as they were then (version {e.settings_version}), at{' '}
        {new Date(e.served_at).toLocaleString()}.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: space.lg },
  lead: { color: colors.text, fontSize: 16 },
  strong: { fontWeight: '700' },
  rows: { gap: space.md },
  row: { flexDirection: 'row', gap: space.md, alignItems: 'flex-start' },
  rowText: { flex: 1, gap: 2 },
  rowRight: { alignItems: 'flex-end', gap: space.xs },
  label: { color: colors.text, fontSize: 15, fontWeight: '600' },
  detail: { color: colors.textMuted, fontSize: 12 },
  barTrack: { height: 4, backgroundColor: colors.surfaceRaised, borderRadius: radius.pill, marginTop: 4 },
  bar: { height: 4, backgroundColor: colors.accent, borderRadius: radius.pill },
  barNegative: { backgroundColor: colors.danger },
  amount: { color: colors.success, fontSize: 15, fontWeight: '700', fontVariant: ['tabular-nums'] },
  negative: { color: colors.danger },
  adjust: { color: colors.accent, fontSize: 13, fontWeight: '600' },
  total: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    borderTopWidth: 1,
    borderColor: colors.border,
    paddingTop: space.md,
  },
  totalLabel: { color: colors.text, fontSize: 16, fontWeight: '700' },
  totalValue: { color: colors.text, fontSize: 16, fontWeight: '700', fontVariant: ['tabular-nums'] },
  footnote: { color: colors.textMuted, fontSize: 12 },
});
