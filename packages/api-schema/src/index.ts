import createClient, { type Middleware } from "openapi-fetch";

import type { components, paths } from "./schema";

export type { components, paths };

/** Named shortcuts for the API's JSON schemas, e.g. `Schemas["ContentItem"]`. */
export type Schemas = components["schemas"];

export type ApiClient = ReturnType<typeof createApiClient>;

/**
 * Typed client for the T-Spec API. `getToken` is called per request so the
 * client picks up sign-in/sign-out without being recreated.
 */
export function createApiClient(
  baseUrl: string,
  getToken: () => string | null | undefined | Promise<string | null | undefined>,
) {
  const client = createClient<paths>({ baseUrl });

  const auth: Middleware = {
    async onRequest({ request }) {
      const token = await getToken();
      if (token) request.headers.set("Authorization", `Bearer ${token}`);
      return request;
    },
  };

  client.use(auth);
  return client;
}
