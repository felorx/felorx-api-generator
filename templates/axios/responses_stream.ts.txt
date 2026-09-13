export interface FelorxResponseStreamEvent {
    type: string;
    data: Record<string, unknown>;
    /** Original JSON, including exact numeric spelling beyond JS safe integers. */
    rawData: string;
}

/** An owned reader, compatible with ReadableStream<Uint8Array>.getReader(). */
export interface FelorxResponseByteReader {
    read(): Promise<{ done: boolean; value?: Uint8Array }>;
    cancel(reason?: unknown): Promise<unknown>;
    releaseLock(): void;
}

/** Takes ownership of the reader. Delivery is sequential and awaits the sink;
 * cancellation interrupts both a blocked read and a blocked sink. Sink code
 * should also observe the signal when it performs its own asynchronous work. */
export async function readResponsesStream(
    reader: FelorxResponseByteReader,
    emit: (event: FelorxResponseStreamEvent) => void | Promise<void>,
    signal?: AbortSignal,
): Promise<void> {
    const decoder = new FelorxResponsesSseDecoder();
    let rejectAbort: (reason: unknown) => void = () => {};
    const aborted = new Promise<never>((_, reject) => { rejectAbort = reject; });
    // Attach immediately, including for a signal already aborted on entry.
    void aborted.catch(() => {});
    const onAbort = () => {
        const error = new Error('Responses stream cancelled');
        error.name = 'AbortError';
        rejectAbort(error);
    };
    signal?.addEventListener('abort', onAbort, { once: true });
    try {
        if (signal?.aborted) { onAbort(); await aborted; }
        while (!decoder.completed) {
            const chunk = await Promise.race([reader.read(), aborted]);
            if (chunk.done) { decoder.finish(); return; }
            if (!(chunk.value instanceof Uint8Array)) throw new Error('Invalid Responses stream chunk');
            for (const event of decoder.push(chunk.value)) {
                if (signal?.aborted) { onAbort(); await aborted; }
                await Promise.race([Promise.resolve().then(() => emit(event)), aborted]);
            }
        }
    } finally {
        signal?.removeEventListener('abort', onAbort);
        // Do not let a stalled underlying cancellation delay terminal delivery
        // or replace the original decoding/sink error with a cleanup error.
        try { void reader.cancel().catch(() => {}); } catch (_) {}
        try { reader.releaseLock(); } catch (_) {}
    }
}

/** Incremental UTF-8/SSE decoder. Consume each yielded event before requesting
 * the next one; completed/error events terminate without waiting for EOF. */
export class FelorxResponsesSseDecoder {
    private readonly decoder = new TextDecoder('utf-8', { fatal: true });
    private line = '';
    private data: string[] = [];
    private event = '';
    private frameBytes = 0;
    private afterCR = false;
    private ended = false;

    get completed(): boolean { return this.ended; }

    *push(chunk: Uint8Array): IterableIterator<FelorxResponseStreamEvent> {
        if (this.ended) return;
        const text = this.decoder.decode(chunk, { stream: true });
        for (const character of text) {
            if (this.afterCR && character === '\n') { this.afterCR = false; continue; }
            this.afterCR = character === '\r';
            const point = character.codePointAt(0)!;
            this.frameBytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
            if (this.frameBytes > 8 * 1024 * 1024) throw new Error('Responses SSE frame exceeds limit');
            if (character !== '\r' && character !== '\n') { this.line += character; continue; }
            const line = this.line;
            this.line = '';
            if (line === '') {
                this.frameBytes = 0;
                const event = this.dispatch();
                if (event) yield event;
                if (this.ended) return;
                continue;
            }
            if (line.startsWith(':')) continue;
            const colon = line.indexOf(':');
            const field = colon < 0 ? line : line.slice(0, colon);
            let value = colon < 0 ? '' : line.slice(colon + 1);
            if (value.startsWith(' ')) value = value.slice(1);
            if (field === 'data') this.data.push(value);
            else if (field === 'event') this.event = value;
        }
    }

    finish(): void {
        if (this.ended) return;
        this.decoder.decode(); // Reject an incomplete final UTF-8 code point.
        throw new Error('Responses stream ended before a terminal event');
    }

    private dispatch(): FelorxResponseStreamEvent | undefined {
        if (this.data.length === 0) { this.event = ''; return undefined; }
        const rawData = this.data.join('\n');
        if (rawData === '[DONE]') throw new Error('Responses stream ended before a terminal event');
        const data: unknown = JSON.parse(rawData);
        if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error('Invalid Responses event');
        const object = data as Record<string, unknown>;
        const type = object.type;
        if (typeof type !== 'string' || (type !== 'error' && !type.startsWith('response.')) || (this.event !== '' && this.event !== type)) throw new Error('Invalid Responses event type');
        this.data = [];
        this.event = '';
        this.ended = ['error', 'response.completed', 'response.failed', 'response.incomplete', 'response.cancelled'].includes(type);
        return { type, data: object, rawData };
    }
}
