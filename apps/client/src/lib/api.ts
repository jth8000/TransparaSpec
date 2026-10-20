import { createApiClient, type Schemas } from '@tspec/api-schema';

import { API_URL } from './config';

export type { Schemas };

// The current bearer token, kept in sync by SessionProvider. A module-level
// value (rather than React state) so the client never needs recreating.
let currentToken: string | null = null;

export function setApiToken(token: string | null) {
  currentToken = token;
}

export function getApiToken() {
  return currentToken;
}

export const api = createApiClient(API_URL, () => currentToken);

/** Thrown by `unwrap` for non-2xx responses; carries the API's Error body. */
export class ApiError extends Error {
  constructor(
    public status: number,
    public body: Schemas['Error'] | undefined,
  ) {
    super(body?.message ?? `Request failed (${status})`);
  }

  /** First message per field, for showing under form inputs. */
  fieldMessage(field: string): string | undefined {
    return this.body?.fields?.[field]?.[0];
  }
}

/**
 * Turns an openapi-fetch result into its data or a thrown ApiError, so it can
 * be used directly as a React Query `queryFn` / `mutationFn`.
 */
export async function unwrap<T>(
  promise: Promise<{ data?: T; error?: unknown; response: Response }>,
): Promise<T> {
  const { data, error, response } = await promise;
  if (!response.ok) throw new ApiError(response.status, error as Schemas['Error'] | undefined);
  return data as T;
}
