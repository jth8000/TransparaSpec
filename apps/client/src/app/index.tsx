import { Redirect } from 'expo-router';

import { useSession } from '@/lib/session';

/** Entry point and guard fallback: sends each session state to its home. */
export default function Index() {
  const { token, me } = useSession();

  if (!token || !me) return <Redirect href="/sign-in" />;
  if (!me.onboarded) return <Redirect href="/onboarding" />;
  return <Redirect href="/feed" />;
}
