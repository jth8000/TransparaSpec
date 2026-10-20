import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useLocalSearchParams } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';

import { Button, ErrorText, Screen } from '@/components/ui';
import { api, unwrap } from '@/lib/api';
import { useSession } from '@/lib/session';
import { colors, radius, space } from '@/theme';

export default function UserProfile() {
  const { handle } = useLocalSearchParams<{ handle: string }>();
  const { me } = useSession();
  const queryClient = useQueryClient();
  const key = ['user', handle];

  const profile = useQuery({
    queryKey: key,
    queryFn: () => unwrap(api.GET('/api/users/{handle}', { params: { path: { handle } } })),
  });

  const follow = useMutation({
    mutationFn: (following: boolean) => {
      const params = { params: { path: { handle } } };
      return unwrap(
        following
          ? api.DELETE('/api/users/{handle}/follow', params)
          : api.POST('/api/users/{handle}/follow', params),
      );
    },
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: key });
      void queryClient.invalidateQueries({ queryKey: ['feed', 'following'] });
    },
  });

  if (profile.isLoading) return <Screen title="Loading…" />;
  if (!profile.data) return <Screen title="Not found" subtitle={`No user @${handle}.`} />;

  const p = profile.data;
  const isMe = me?.id === p.id;

  return (
    <Screen>
      <View style={styles.header}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{p.handle[0]?.toUpperCase()}</Text>
        </View>
        <Text style={styles.name}>{p.display_name ?? `@${p.handle}`}</Text>
        <Text style={styles.handle}>@{p.handle}</Text>
        {p.bio ? <Text style={styles.bio}>{p.bio}</Text> : null}
        <View style={styles.counts}>
          <Text style={styles.count} testID="followers-count">
            <Text style={styles.countNum}>{p.followers_count}</Text> followers
          </Text>
          <Text style={styles.count}>
            <Text style={styles.countNum}>{p.following_count}</Text> following
          </Text>
        </View>
      </View>
      {!isMe && (
        <Button
          testID="follow-button"
          title={p.followed_by_me ? 'Following' : 'Follow'}
          variant={p.followed_by_me ? 'secondary' : 'primary'}
          loading={follow.isPending}
          onPress={() => follow.mutate(p.followed_by_me)}
        />
      )}
      <ErrorText>{follow.error?.message}</ErrorText>
    </Screen>
  );
}

const styles = StyleSheet.create({
  header: { alignItems: 'center', gap: space.xs },
  avatar: {
    width: 88,
    height: 88,
    borderRadius: radius.pill,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarText: { color: colors.text, fontSize: 36, fontWeight: '800' },
  name: { color: colors.text, fontSize: 22, fontWeight: '800' },
  handle: { color: colors.textMuted },
  bio: { color: colors.text, textAlign: 'center', marginTop: space.sm },
  counts: { flexDirection: 'row', gap: space.xl, marginTop: space.md },
  count: { color: colors.textMuted },
  countNum: { color: colors.text, fontWeight: '700' },
});
