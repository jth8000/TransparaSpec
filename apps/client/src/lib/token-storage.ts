import * as SecureStore from 'expo-secure-store';

// Native: the bearer token lives in the OS keychain/keystore.
const KEY = 'tspec.session.token';

export async function loadToken(): Promise<string | null> {
  return SecureStore.getItemAsync(KEY);
}

export async function saveToken(token: string | null): Promise<void> {
  if (token) await SecureStore.setItemAsync(KEY, token);
  else await SecureStore.deleteItemAsync(KEY);
}
