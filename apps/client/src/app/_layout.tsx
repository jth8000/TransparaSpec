import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { DarkTheme, Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';

import { Button, Screen } from '@/components/ui';
import { EventsProvider } from '@/lib/events';
import { SessionProvider, useSession } from '@/lib/session';
import { colors } from '@/theme';

SplashScreen.preventAutoHideAsync();

const theme = {
  ...DarkTheme,
  colors: { ...DarkTheme.colors, background: colors.bg, card: colors.bg, primary: colors.accent },
};

export default function RootLayout() {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <QueryClientProvider client={queryClient}>
      <SessionProvider>
        <EventsProvider>
          <ThemeProvider value={theme}>
            <StatusBar style="light" />
            <RootStack />
          </ThemeProvider>
        </EventsProvider>
      </SessionProvider>
    </QueryClientProvider>
  );
}

/**
 * Three states, each guarding its own routes:
 * signed out → (auth); signed in but not onboarded → onboarding;
 * onboarded → the app.
 */
function RootStack() {
  const { isLoading, restoreFailed, retryRestore, token, me } = useSession();

  useEffect(() => {
    if (!isLoading) SplashScreen.hide();
  }, [isLoading]);

  if (isLoading) return null;

  // The stored session couldn't be checked (offline, or a server error).
  // It's kept, so retrying, or the next launch, signs straight back in.
  if (restoreFailed) {
    return (
      <Screen title="Can't reach T-Spec" subtitle="Check your connection and try again.">
        <Button title="Try again" testID="retry-restore" onPress={() => void retryRestore()} />
      </Screen>
    );
  }

  const signedIn = !!token && !!me;
  const onboarded = signedIn && me.onboarded;

  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Screen name="index" />
      <Stack.Protected guard={!signedIn}>
        <Stack.Screen name="(auth)" />
      </Stack.Protected>
      <Stack.Protected guard={signedIn && !onboarded}>
        <Stack.Screen name="onboarding" />
      </Stack.Protected>
      <Stack.Protected guard={onboarded}>
        <Stack.Screen name="(tabs)" />
        <Stack.Screen
          name="u/[handle]"
          options={{ headerShown: true, title: '', headerTransparent: true }}
        />
        <Stack.Screen
          name="why/[impressionId]"
          options={{ presentation: 'modal', headerShown: true, title: 'Why you’re seeing this' }}
        />
      </Stack.Protected>
    </Stack>
  );
}
