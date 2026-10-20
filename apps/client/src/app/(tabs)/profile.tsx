import { router } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button, ErrorText, Field, Screen } from '@/components/ui';
import { api, ApiError, unwrap } from '@/lib/api';
import { useSession } from '@/lib/session';
import { colors, radius, space } from '@/theme';

export default function Profile() {
  const { me, setMe, signOut } = useSession();
  const [displayName, setDisplayName] = useState(me?.display_name ?? '');
  const [bio, setBio] = useState(me?.bio ?? '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();

  if (!me) return null;

  const save = async () => {
    setSaving(true);
    setError(undefined);
    try {
      setMe(await unwrap(api.PATCH('/api/me', { body: { display_name: displayName, bio } })));
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not save');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Screen>
      <View style={styles.header}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{me.handle?.[0]?.toUpperCase()}</Text>
        </View>
        <Text style={styles.handle}>@{me.handle}</Text>
        <Text style={styles.email}>{me.email}</Text>
      </View>

      <Field label="Display name" value={displayName} onChangeText={setDisplayName} maxLength={50} />
      <Field label="Bio" value={bio} onChangeText={setBio} multiline maxLength={300} />
      <ErrorText>{error}</ErrorText>
      <Button title="Save" onPress={save} loading={saving} />
      <Button title="View public profile" variant="secondary" onPress={() => router.push(`/u/${me.handle}`)} />
      <Button title="Sign out" variant="secondary" testID="sign-out" onPress={signOut} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  header: { alignItems: 'center', gap: space.xs },
  avatar: {
    width: 72,
    height: 72,
    borderRadius: radius.pill,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarText: { color: colors.accentText, fontSize: 30, fontWeight: '800' },
  handle: { color: colors.text, fontSize: 20, fontWeight: '700' },
  email: { color: colors.textMuted },
});
