import { AxiosHeaders } from 'axios';
import type { RawAxiosRequestConfig } from 'axios';
import { ResponsesApi, ResponsesApiAxiosParamCreator } from './api';
import type { FelorxResponsesCreateRequest } from './api';
import { operationServerMap } from './base';
import { streamResponses } from './responses_http';
import type { FelorxResponseStreamEvent } from './responses_stream';

export interface ResponsesApiCreateRawStreamRequest {
    body: Record<string, unknown>;
    xFelorxAiProvider?: string;
}

/** Drop-in ResponsesApi subclass retaining all generated non-stream methods. */
export class ResponsesStreamApi extends ResponsesApi {
    createResponseRawStream(
        parameters: ResponsesApiCreateRawStreamRequest,
        emit: (event: FelorxResponseStreamEvent) => void | Promise<void>,
        options?: RawAxiosRequestConfig,
    ): Promise<void> { return this.stream(false, parameters, emit, options); }

    createResponseLegacyRawStream(
        parameters: ResponsesApiCreateRawStreamRequest,
        emit: (event: FelorxResponseStreamEvent) => void | Promise<void>,
        options?: RawAxiosRequestConfig,
    ): Promise<void> { return this.stream(true, parameters, emit, options); }

    private async stream(
        legacy: boolean,
        parameters: ResponsesApiCreateRawStreamRequest,
        emit: (event: FelorxResponseStreamEvent) => void | Promise<void>,
        options?: RawAxiosRequestConfig,
    ): Promise<void> {
        const operation = legacy ? 'createResponseLegacy' : 'createResponse';
        // Reuse the generator's async access-token resolution and header/options
        // precedence; retain the original raw body for extension fields.
        const args = await ResponsesApiAxiosParamCreator(this.configuration)[operation](
            parameters.body as FelorxResponsesCreateRequest, parameters.xFelorxAiProvider, options,
        );
        const headers = AxiosHeaders.from(this.axios.defaults.headers.common as Record<string, string>)
            .concat(this.axios.defaults.headers.post as Record<string, string>, args.options.headers);
        const authorization = headers.get('Authorization');
        if (typeof authorization !== 'string' || !/^Bearer\s+\S/i.test(authorization)) throw new Error('Responses bearer authentication is required');
        const provider = headers.get('X-Felorx-Ai-Provider');
        if (provider != null && typeof provider !== 'string') throw new Error('Invalid Responses provider');
        const operationBase = operationServerMap[`ResponsesApi.${operation}`]?.[this.configuration?.serverIndex ?? 0]?.url;
        const base = this.axios.defaults.baseURL
            ? args.options.baseURL || this.axios.defaults.baseURL
            : this.configuration?.basePath ?? operationBase ?? this.basePath;
        const adapter = args.options.adapter;
        if (adapter !== undefined && adapter !== 'http' && adapter !== 'fetch') throw new Error('Responses requires the fetch or http adapter');
        await streamResponses({
            endpoint: base.replace(/\/+$/, '') + args.url,
            bearerToken: authorization.replace(/^Bearer\s+/i, ''),
            provider: provider == null ? undefined : provider as string,
            headers: headers.toJSON(true) as Record<string, string>,
            client: this.axios,
            adapter: adapter as 'http' | 'fetch' | undefined,
            signal: args.options.signal as AbortSignal | undefined,
            requestOptions: args.options,
        }, parameters.body, emit);
    }
}
