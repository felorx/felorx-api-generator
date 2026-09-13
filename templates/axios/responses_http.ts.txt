import axios from 'axios';
import type { AxiosInstance, AxiosRequestConfig } from 'axios';
import { readResponsesStream } from './responses_stream';
import type { FelorxResponseByteReader, FelorxResponseStreamEvent } from './responses_stream';

export interface FelorxResponseStreamOptions {
    endpoint: string;
    bearerToken: string;
    provider?: string;
    headers?: Record<string, string>;
    client?: AxiosInstance;
    /** Fetch works in browsers and modern Node; http selects the Node adapter. */
    adapter?: 'fetch' | 'http';
    signal?: AbortSignal;
    /** Transport options; method, URL, body, auth and streaming invariants are enforced. */
    requestOptions?: AxiosRequestConfig;
}

export class FelorxResponseHTTPError extends Error {
    readonly statusCode: number;
    /** Bounded parsed JSON, available explicitly; omitted from the message. */
    readonly body: unknown;
    constructor(statusCode: number, body?: unknown) {
        super(`Responses HTTP request failed (${statusCode})`);
        this.name = 'FelorxResponseHTTPError';
        this.statusCode = statusCode;
        this.body = body;
    }
}

/** Adapts Web streams and Node byte streams without buffering the response. */
export function responseByteReader(source: unknown): FelorxResponseByteReader {
    if (source && typeof (source as ReadableStream<Uint8Array>).getReader === 'function') {
        return (source as ReadableStream<Uint8Array>).getReader();
    }
    const node = source as { [Symbol.asyncIterator]?: () => AsyncIterator<Uint8Array>; destroy?: () => void };
    if (!node || typeof node[Symbol.asyncIterator] !== 'function' || typeof node.destroy !== 'function') {
        throw new Error('Responses adapter did not return a byte stream');
    }
    const iterator = node[Symbol.asyncIterator]!();
    return {
        async read() { const next = await iterator.next(); return { done: !!next.done, value: next.value }; },
        async cancel() { node.destroy!(); },
        releaseLock() {},
    };
}

function abortError(): Error {
    const error = new Error('Responses stream cancelled');
    error.name = 'AbortError';
    return error;
}

/** POST a raw Responses body. The caller's body and headers are not mutated. */
export async function streamResponses(
    options: FelorxResponseStreamOptions,
    body: Record<string, unknown>,
    emit: (event: FelorxResponseStreamEvent) => void | Promise<void>,
): Promise<void> {
    let url: URL;
    try { url = new URL(options.endpoint); } catch (_) { throw new Error('Invalid Responses endpoint'); }
    if (!['http:', 'https:'].includes(url.protocol) || !url.host || url.username || url.password || url.search || url.hash) throw new Error('Invalid Responses endpoint');
    if (!options.bearerToken?.trim() || /[\r\n]/.test(options.bearerToken)) throw new Error('Invalid Responses bearer token');
    if (options.provider !== undefined && (!options.provider.trim() || /[\r\n]/.test(options.provider))) throw new Error('Invalid Responses provider');
    if (!body || typeof body !== 'object' || Array.isArray(body) || typeof emit !== 'function') throw new Error('Invalid Responses request');
    const headers: Record<string, string> = {};
    for (const [name, value] of Object.entries(options.headers || {})) {
        if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) || typeof value !== 'string' || /[\r\n]/.test(value)) throw new Error('Invalid Responses header');
        if (['authorization', 'content-type', 'accept', 'x-felorx-ai-provider', 'content-length', 'host'].includes(name.toLowerCase())) continue;
        headers[name] = value;
    }
    headers.Authorization = `Bearer ${options.bearerToken}`;
    headers['Content-Type'] = 'application/json';
    headers.Accept = 'text/event-stream';
    if (options.provider !== undefined) headers['X-Felorx-Ai-Provider'] = options.provider;
    let json: string;
    try { json = JSON.stringify({ ...body, stream: true }); } catch (_) { throw new Error('Invalid Responses JSON request'); }
    const serialized = JSON.parse(json);
    if (!serialized || Array.isArray(serialized) || serialized.stream !== true) throw new Error('Invalid Responses JSON request');
    if (new TextEncoder().encode(json).byteLength > 8 * 1024 * 1024) throw new Error('Responses request exceeds limit');
    if (options.signal?.aborted) throw abortError();
    const lifetime = new AbortController();
    const onAbort = () => lifetime.abort();
    options.signal?.addEventListener('abort', onAbort, { once: true });
    let reader: FelorxResponseByteReader | undefined;
    try {
        const config: AxiosRequestConfig = {
            ...options.requestOptions,
            method: 'POST', url: url.href, data: json, headers,
            adapter: options.adapter || 'fetch', responseType: 'stream',
            signal: lifetime.signal, maxRedirects: 0,
            fetchOptions: { redirect: 'error' },
            auth: null as unknown as AxiosRequestConfig['auth'], params: null,
            withCredentials: false, xsrfCookieName: null as unknown as string,
            transformRequest: [(data: unknown) => data], transformResponse: [(data: unknown) => data],
            validateStatus: () => true,
        };
        let response;
        try { response = await (options.client || axios).request(config); }
        catch (_) {
            if (lifetime.signal.aborted) throw abortError();
            // Axios errors retain request config, including Authorization.
            throw new Error('Responses transport request failed');
        }
        reader = responseByteReader(response.data);
        if (response.status < 200 || response.status >= 300) {
            const parts: Uint8Array[] = [];
            let length = 0;
            let parsed: unknown;
            try {
                while (true) {
                    const next = await reader.read();
                    if (next.done) break;
                    if (!(next.value instanceof Uint8Array)) throw new Error('Invalid error body');
                    length += next.value.byteLength;
                    if (length > 64 * 1024) throw new Error('Error body exceeds limit');
                    parts.push(next.value);
                }
                const bytes = new Uint8Array(length);
                let offset = 0;
                for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
                parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
            } catch (_) { /* Preserve status even for an invalid or oversized error body. */ }
            if (lifetime.signal.aborted) throw abortError();
            throw new FelorxResponseHTTPError(response.status, parsed);
        }
        if (!/^text\/event-stream(?:\s*;|\s*$)/i.test(String(response.headers['content-type'] || ''))) throw new Error('Responses server did not return an SSE stream');
        const owned = reader;
        reader = undefined;
        await readResponsesStream({
            read: () => owned.read(),
            cancel: () => { lifetime.abort(); return owned.cancel(); },
            releaseLock: () => owned.releaseLock(),
        }, emit, lifetime.signal);
    } finally {
        // Abort before reader cancellation: an Axios fetch wrapper can remove
        // its signal subscription when cancelled while a prefetch is pending.
        lifetime.abort();
        if (reader) {
            try { void reader.cancel().catch(() => {}); } catch (_) {}
            try { reader.releaseLock(); } catch (_) {}
        }
        options.signal?.removeEventListener('abort', onAbort);
    }
}
