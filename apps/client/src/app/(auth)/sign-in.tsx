import { router } from 'expo-router';
import { useState } from 'react';

import { Button, ErrorText, Field, Screen } from '@/components/ui';
import { api, ApiError, unwrap } from '@/lib/api';

/** Sign in / sign up: one email field. The API emails a code and a magic link. */
export default function SignIn() {
  const [email, setEmail] = useState('');
  const [error, setError] = useState<string>();
  const [sending, setSending] = useState(false);

  const submit = async () => {
    setError(undefined);
    setSending(true);
    try {
      await unwrap(api.POST('/api/auth/request', { body: { email: email.trim() } }));
      router.push({ pathname: '/verify', params: { email: email.trim() } });
    } catch (e) {
      setError(e instanceof ApiError ? (e.fieldMessage('email') ?? e.message) : 'Something went wrong');
    } finally {
      setSending(false);
    }
  };

  return (
    <Screen
      title="T-Spec"
      subtitle="See why you're shown what you're shown. Enter your email to sign in or create an account.">
      <Field
        label="Email"
        testID="email-input"
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        placeholder="you@example.com"
        onSubmitEditing={submit}
      />
      <ErrorText>{error}</ErrorText>
      <Button title="Email me a code" testID="request-code" onPress={submit} loading={sending} disabled={!email.includes('@')} />
    </Screen>
  );
}
