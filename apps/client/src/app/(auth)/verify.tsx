import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useRef, useState } from 'react';

import { Button, ErrorText, Field, Screen } from '@/components/ui';
import { api, ApiError, unwrap } from '@/lib/api';
import { useSession } from '@/lib/session';

/**
 * Enter the 6-digit code from the email. Also the landing page for the magic
 * link on web (`/verify?token=…`), which signs in without typing anything.
 */
export default function Verify() {
  const { email, token } = useLocalSearchParams<{ email?: string; token?: string }>();
  const { signIn } = useSession();
  const [code, setCode] = useState('');
  const [error, setError] = useState<string>();
  const [verifying, setVerifying] = useState(false);
  const usedLink = useRef(false);

  const verify = async (body: { email: string; code: string } | { token: string }) => {
    setError(undefined);
    setVerifying(true);
    try {
      await signIn(await unwrap(api.POST('/api/auth/verify', { body })));
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Something went wrong');
      setVerifying(false);
    }
  };

  useEffect(() => {
    if (token && !usedLink.current) {
      usedLink.current = true;
      void verify({ token });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  if (token) {
    return (
      <Screen title={verifying ? 'Signing you in…' : 'Link expired'} subtitle={error}>
        {!verifying && <Button title="Back to sign in" onPress={() => router.replace('/sign-in')} />}
      </Screen>
    );
  }

  return (
    <Screen title="Check your email" subtitle={`We sent a 6-digit code to ${email ?? 'your email'}.`}>
      <Field
        label="Code"
        testID="code-input"
        value={code}
        onChangeText={(text) => setCode(text.replace(/\D/g, '').slice(0, 6))}
        keyboardType="number-pad"
        autoComplete="one-time-code"
        placeholder="123456"
        maxLength={6}
      />
      <ErrorText>{error}</ErrorText>
      <Button
        title="Sign in"
        testID="verify-code"
        onPress={() => email && verify({ email, code })}
        loading={verifying}
        disabled={code.length !== 6 || !email}
      />
      <Button title="Use a different email" variant="secondary" onPress={() => router.back()} />
    </Screen>
  );
}
