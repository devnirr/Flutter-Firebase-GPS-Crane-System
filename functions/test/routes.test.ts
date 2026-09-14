import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * The road the server routes once, for every screen that will draw it.
 *
 * Before this the apps each fetched their own: the customer's phone, the
 * chofer's phone and the dispatcher's browser paid for the same line, drew
 * three slightly different ones, and on the web could not fetch it at all.
 *
 * The fallback matters as much as the success — without a key, or with the
 * Routes API disabled, a tow still has to be drawn and priced.
 */

const key = { value: () => '' };
vi.mock('../src/lib/secrets.js', () => ({
  mapsApiKey: { value: () => key.value() },
  quoteSigningSecret: { value: () => 'test' },
}));
vi.mock('firebase-functions/v2', () => ({
  logger: { info: () => {}, warn: () => {}, error: () => {} },
}));

const jarabacoa = { latitude: 19.1221, longitude: -70.6367 };
const santiago = { latitude: 19.4517, longitude: -70.697 };

/** The Routes API's answer, trimmed to the fields the helper reads. */
const answer = (over: Record<string, unknown> = {}) =>
  new Response(
    JSON.stringify({
      routes: [
        {
          distanceMeters: 52340,
          duration: '3600s',
          polyline: { encodedPolyline: 'ohq`Bp|niN_pR_pR~eA_pR' },
          ...over,
        },
      ],
    }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );

describe('roadRoute', () => {
  let sent: Record<string, unknown> | undefined;
  let header: string | undefined;

  beforeEach(() => {
    vi.resetModules();
    sent = undefined;
    header = undefined;
    key.value = () => 'a-key';
  });
  afterEach(() => vi.unstubAllGlobals());

  it('returns the road, its length and its polyline', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => answer()));
    const { roadRoute } = await import('../src/lib/routes.js');

    const route = await roadRoute(jarabacoa, santiago);

    expect(route).not.toBeNull();
    expect(route!.distanceMeters).toBe(52340);
    expect(route!.durationSeconds).toBe(3600);
    expect(route!.polyline).toBe('ohq`Bp|niN_pR_pR~eA_pR');
  });

  it('asks for a traffic-unaware route, so two calls agree', async () => {
    // `requestService` recomputes what `quoteService` quoted and checks the
    // signature against it. A traffic-aware answer is by design not stable, and
    // an unstable one would refuse every request as a price mismatch.
    const fetcher = vi.fn(async (_url: string, init: RequestInit) => {
      sent = JSON.parse(init.body as string) as Record<string, unknown>;
      return answer();
    });
    vi.stubGlobal('fetch', fetcher);
    const { roadRoute } = await import('../src/lib/routes.js');

    await roadRoute(jarabacoa, santiago);

    const body = sent!;
    expect(body.routingPreference).toBe('TRAFFIC_UNAWARE');
    expect(body.travelMode).toBe('DRIVE');
  });

  it('is null without a key, and never calls out', async () => {
    key.value = () => '';
    const fetcher = vi.fn(async () => answer());
    vi.stubGlobal('fetch', fetcher);
    const { roadRoute } = await import('../src/lib/routes.js');

    expect(await roadRoute(jarabacoa, santiago)).toBeNull();
    expect(fetcher).not.toHaveBeenCalled();
  });

  it('is null when the API is disabled, rather than throwing', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('Routes API has not been used', { status: 403 })),
    );
    const { roadRoute } = await import('../src/lib/routes.js');

    expect(await roadRoute(jarabacoa, santiago)).toBeNull();
  });

  it('is null when the call throws, rather than taking the quote down', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('timeout'); }));
    const { roadRoute } = await import('../src/lib/routes.js');

    expect(await roadRoute(jarabacoa, santiago)).toBeNull();
  });

  it('reuses the answer for the same trip', async () => {
    // A quote and the request that follows it are two calls about one trip.
    const fetcher = vi.fn(async () => answer());
    vi.stubGlobal('fetch', fetcher);
    const { roadRoute } = await import('../src/lib/routes.js');

    await roadRoute(jarabacoa, santiago);
    await roadRoute(jarabacoa, santiago);

    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it('survives a key pasted with a stray newline', async () => {
    // How this secret is set: pasted at a prompt, or piped from a shell that
    // ends its lines. Node throws on a header value containing a newline, so
    // an untrimmed key would fail every call silently.
    key.value = () => 'a-key\r\n';
    const fetcher = vi.fn(async (_url: string, init: RequestInit) => {
      header = (init.headers as Record<string, string>)['X-Goog-Api-Key'];
      return answer();
    });
    vi.stubGlobal('fetch', fetcher);
    const { roadRoute } = await import('../src/lib/routes.js');

    expect(await roadRoute(jarabacoa, santiago)).not.toBeNull();
    expect(header).toBe('a-key');
  });

  it('treats a key that is only whitespace as no key at all', async () => {
    key.value = () => '  \n';
    const fetcher = vi.fn(async () => answer());
    vi.stubGlobal('fetch', fetcher);
    const { roadRoute } = await import('../src/lib/routes.js');

    expect(await roadRoute(jarabacoa, santiago)).toBeNull();
    expect(fetcher).not.toHaveBeenCalled();
  });

  it('refuses an answer with no distance', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => answer({ distanceMeters: 0 })));
    const { roadRoute } = await import('../src/lib/routes.js');

    expect(await roadRoute(jarabacoa, santiago)).toBeNull();
  });
});
