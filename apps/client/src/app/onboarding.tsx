import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, ErrorText, Field, Screen } from '@/components/ui';
import { api, ApiError, unwrap } from '@/lib/api';
import { useSession } from '@/lib/session';
import { colors, radius, space } from '@/theme';

const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Handle, 13+ check and terms. The birthdate is checked by the server and never stored. */
export default function Onboarding() {
  const { setMe, signOut } = useSession();
  const consent = useQuery({
    queryKey: ['consent'],
    queryFn: () => unwrap(api.GET('/api/consent/current')),
  });

  const [handle, setHandle] = useState('');
  const [birthdate, setBirthdate] = useState('');
  const [accepted, setAccepted] = useState(false);
  const [error, setError] = useState<ApiError>();
  const [saving, setSaving] = useState(false);

  const submit = async () => {
    if (!consent.data) return;
    setError(undefined);
    setSaving(true);
    try {
      const me = await unwrap(
        api.POST('/api/onboarding', {
          body: { handle, birthdate, accept_consent_version: consent.data.version },
        }),
      );
      setMe(me);
    } catch (e) {
      if (e instanceof ApiError && e.body?.error === 'age_requirement') {
        // The account was deleted server-side.
        await signOut();
        return;
      }
      setError(e instanceof ApiError ? e : undefined);
      setSaving(false);
    }
  };

  return (
    <Screen title="Set up your profile" subtitle="Pick a handle. You can change your display name later.">
      <Field
        label="Handle"
        testID="handle-input"
        value={handle}
        onChangeText={(t) => setHandle(t.toLowerCase())}
        autoCapitalize="none"
        placeholder="your_handle"
        hint="3–30 characters: letters, numbers, underscores"
        error={error?.fieldMessage('handle')}
      />
      <Field
        label="Date of birth"
        testID="birthdate-input"
        value={birthdate}
        onChangeText={setBirthdate}
        placeholder="YYYY-MM-DD"
        hint="You must be 13 or older. We check it and don't store it."
        error={error?.fieldMessage('birthdate')}
      />

      <Pressable
        testID="accept-terms"
        accessibilityRole="checkbox"
        accessibilityState={{ checked: accepted }}
        onPress={() => setAccepted((a) => !a)}
        style={styles.checkRow}>
        <View style={[styles.checkbox, accepted && styles.checkboxOn]}>
          {accepted ? <Text style={styles.check}>✓</Text> : null}
        </View>
        <Text style={styles.checkLabel}>
          I agree to the T-Spec Terms and Privacy Policy (v{consent.data?.version ?? '…'}).
        </Text>
      </Pressable>

      <ErrorText>{error && !error.body?.fields ? error.message : undefined}</ErrorText>
      <Button
        title="Continue"
        testID="finish-onboarding"
        onPress={submit}
        loading={saving}
        disabled={!accepted || handle.length < 3 || !DATE.test(birthdate) || !consent.data}
      />
      <Button title="Sign out" variant="secondary" onPress={signOut} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  checkRow: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  checkbox: {
    width: 24,
    height: 24,
    borderRadius: radius.sm,
    borderWidth: 2,
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  checkboxOn: { backgroundColor: colors.accent, borderColor: colors.accent },
  check: { color: colors.accentText, fontWeight: '800' },
  checkLabel: { color: colors.text, flex: 1, fontSize: 14, lineHeight: 20 },
});
