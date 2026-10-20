/**
 * API base URL. Defaults to localhost: on web that's this machine, and on the
 * Android emulator `make android` runs `adb reverse tcp:4000 tcp:4000` so the
 * emulator's localhost reaches it too.
 */
export const API_URL = (process.env.EXPO_PUBLIC_API_URL ?? 'http://localhost:4000').replace(/\/$/, '');

export const SOCKET_URL = API_URL.replace(/^http/, 'ws') + '/socket';
