import { useQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { ScrollView, StyleSheet, Text } from 'react-native';

import { Explanation } from '@/components/explanation';
import { api, unwrap } from '@/lib/api';
import { colors, space } from '@/theme';

/** "Why am I seeing this?" for one served item (its impression). */
export default function WhyScreen() {
  const { impressionId } = useLocalSearchParams<{ impressionId: string }>();
  const { data, error, isLoading } = useQuery({
    queryKey: ['explanation', impressionId],
    queryFn: () => unwrap(api.GET('/api/impressions/{id}', { params: { path: { id: impressionId } } })),
    // A stored trace never changes.
    staleTime: Infinity,
  });

  const adjust = (topic?: string) => {
    router.back();
    router.navigate({ pathname: '/feed', params: { tune: topic ?? '' } });
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      {isLoading && <Text style={styles.muted}>Loading…</Text>}
      {error && <Text style={styles.error}>Couldn’t load this explanation.</Text>}
      {data && <Explanation explanation={data} onAdjust={adjust} />}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg },
  content: { padding: space.lg, paddingBottom: space.xxl },
  muted: { color: colors.textMuted },
  error: { color: colors.danger },
});
