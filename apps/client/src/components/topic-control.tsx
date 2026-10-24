import Slider from '@react-native-community/slider';
import { StyleSheet, Switch, Text, View } from 'react-native';

import { colors, space } from '@/theme';

type Props = {
  label: string;
  multiplier: number;
  /** Omit for controls without an off switch (candidate sources). */
  hardOff?: boolean;
  /** Following the parent topic's setting. */
  inherited?: boolean;
  onChange: (change: { multiplier?: number; hard_off?: boolean }) => void;
  testID: string;
};

const describe = (m: number) =>
  m === 1 ? 'default' : m === 0 ? 'none' : m > 1 ? `more (${m}×)` : `less (${m}×)`;

/**
 * One algorithm control: a 0–2× slider (1× is the default) and, for topics,
 * an off switch. Moving a topic slider up always raises that topic's items,
 * even ones you've skipped before (ADR 0012).
 */
export function TopicControl({ label, multiplier, hardOff, inherited, onChange, testID }: Props) {
  const off = hardOff === true;
  return (
    <View style={styles.row} testID={testID}>
      <View style={styles.header}>
        <Text style={[styles.label, off && styles.muted]} numberOfLines={1}>
          {label}
        </Text>
        <Text style={styles.value}>
          {off ? 'off' : describe(multiplier)}
          {inherited ? ' · from parent' : ''}
        </Text>
        {hardOff !== undefined && (
          <Switch
            value={!off}
            onValueChange={(on) => onChange({ hard_off: !on })}
            accessibilityLabel={`Show ${label}`}
            testID={`${testID}-switch`}
          />
        )}
      </View>
      <Slider
        value={multiplier}
        minimumValue={0}
        maximumValue={2}
        step={0.25}
        disabled={off}
        onValueChange={(m) => onChange({ multiplier: m })}
        minimumTrackTintColor={colors.accent}
        maximumTrackTintColor={colors.border}
        thumbTintColor={colors.text}
        accessibilityLabel={`${label} weight`}
        testID={`${testID}-slider`}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  row: { gap: space.xs },
  header: { flexDirection: 'row', alignItems: 'center', gap: space.sm },
  label: { flex: 1, color: colors.text, fontSize: 15, fontWeight: '600' },
  muted: { color: colors.textMuted, textDecorationLine: 'line-through' },
  value: { color: colors.textMuted, fontSize: 13 },
});
