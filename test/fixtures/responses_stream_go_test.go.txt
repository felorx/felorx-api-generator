package felorx

import (
    "context"
    "encoding/json"
    "errors"
    "io"
    "net/http"
    "net/http/httptest"
    "strings"
    "testing"
    "time"
)

func TestHTTPStreaming(t *testing.T) {
    stopped := make(chan struct{})
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer close(stopped)
        if r.Method != "POST" || r.Header.Get("Authorization") != "Bearer fixture" || r.Header.Get("X-Felorx-Ai-Provider") != "selected" || r.Header.Get("Accept") != "text/event-stream" { t.Error("request headers") }
        var request map[string]interface{}
        if json.NewDecoder(r.Body).Decode(&request) != nil || request["stream"] != true || request["native_extension"] != "retained" { t.Error("request fields") }
        w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
        io.WriteString(w, "data: {\"type\":\"response.completed\"}\n\n")
        w.(http.Flusher).Flush()
        <-r.Context().Done()
    }))
    defer server.Close()
    ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer cancel()
    body := map[string]interface{}{"input":"hello", "stream":false, "native_extension":"retained"}
    count := 0
    err := StreamResponses(ctx, FelorxResponseStreamOptions{Endpoint:server.URL, BearerToken:"fixture", Provider:"selected"}, body,
        func(FelorxResponseStreamEvent) error { count++; return nil })
    if err != nil || count != 1 || body["stream"] != false { t.Fatalf("stream request: %v", err) }
    select { case <-stopped: case <-ctx.Done(): t.Fatal("terminal did not close HTTP body") }
}

func TestHTTPFailures(t *testing.T) {
    for _, status := range []int{307, 429, 503} {
        calls := 0
        server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            calls++
            w.Header().Set("Location", "/redirected")
            w.WriteHeader(status)
            io.WriteString(w, `{"error":{"code":"fixture_private"}}`)
        }))
        err := StreamResponses(context.Background(), FelorxResponseStreamOptions{Endpoint:server.URL, BearerToken:"fixture"}, map[string]interface{}{}, func(FelorxResponseStreamEvent) error { t.Fatal("unexpected event"); return nil })
        server.Close()
        var failure *FelorxResponseHTTPError
        if !errors.As(err, &failure) || failure.StatusCode != status || calls != 1 || !json.Valid(failure.Body) { t.Fatalf("HTTP failure: %v calls=%d", err, calls) }
        if strings.Contains(err.Error(), "fixture_private") { t.Fatal("error string leaked body") }
    }
}

func TestHTTPErrorBodyIsBounded(t *testing.T) {
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(429)
        io.WriteString(w, `{"message":"`+strings.Repeat("x", 65536)+`"}`)
    }))
    defer server.Close()
    err := StreamResponses(context.Background(), FelorxResponseStreamOptions{Endpoint:server.URL, BearerToken:"fixture"}, map[string]interface{}{}, func(FelorxResponseStreamEvent) error { return nil })
    var failure *FelorxResponseHTTPError
    if !errors.As(err, &failure) || failure.StatusCode != 429 || len(failure.Body) != 0 { t.Fatal("oversized error body retained") }
}

func TestHTTPInvalidOptionsDoNotSend(t *testing.T) {
    calls := 0
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; t.Error("unexpected request") }))
    defer server.Close()
    for _, options := range []FelorxResponseStreamOptions{
        {Endpoint:server.URL, BearerToken:""},
        {Endpoint:server.URL, BearerToken:"fixture\r\nx-injected: yes"},
        {Endpoint:server.URL, BearerToken:"fixture", Provider:"bad\nprovider"},
        {Endpoint:server.URL+"?secret=untrusted", BearerToken:"fixture"},
        {Endpoint:"file:///tmp/responses", BearerToken:"fixture"},
    } {
        if StreamResponses(context.Background(), options, map[string]interface{}{}, func(FelorxResponseStreamEvent) error { return nil }) == nil { t.Error("invalid options accepted") }
    }
    if calls != 0 { t.Fatal("invalid request was sent") }
}

func TestHTTPMimeAndCancel(t *testing.T) {
    started := make(chan struct{})
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/mime" { w.Header().Set("Content-Type", "application/json"); io.WriteString(w, `{}`); return }
        io.Copy(io.Discard, r.Body)
        close(started)
        select { case <-r.Context().Done(): case <-time.After(3*time.Second): t.Error("server did not observe cancelled request") }
    }))
    defer server.Close()
    emit := func(FelorxResponseStreamEvent) error { t.Fatal("unexpected event"); return nil }
    if StreamResponses(context.Background(), FelorxResponseStreamOptions{Endpoint:server.URL+"/mime", BearerToken:"fixture"}, map[string]interface{}{}, emit) == nil { t.Fatal("accepted JSON as SSE") }
    ctx, cancel := context.WithCancel(context.Background())
    done := make(chan error, 1)
    go func() { done <- StreamResponses(ctx, FelorxResponseStreamOptions{Endpoint:server.URL, BearerToken:"fixture"}, map[string]interface{}{}, emit) }()
    select { case <-started: case <-time.After(3*time.Second): cancel(); t.Fatal("request did not start") }
    cancel()
    select { case err := <-done: if !errors.Is(err, context.Canceled) { t.Fatal(err) }; case <-time.After(time.Second): t.Fatal("HTTP cancellation blocked") }
}

type tinyBody struct { input *strings.Reader; closed bool }
func (b *tinyBody) Read(p []byte) (int, error) { return b.input.Read(p[:1]) }
func (b *tinyBody) Close() error { b.closed = true; return nil }

func TestFraming(t *testing.T) {
    for _, newline := range []string{"\n", "\r", "\r\n"} {
        text := strings.Join([]string{
            "\ufeff: comment", "event: response.output_text.delta",
            `data: {"type":"response.output_text.delta",`, `data: "delta":"你好","native_number":9007199254740993}`, "",
            `data: {"type":"response.completed"}`, "", "",
        }, newline)
        body := &tinyBody{input: strings.NewReader(text)}
        count := 0
        err := ReadResponsesStream(context.Background(), body, func(event FelorxResponseStreamEvent) error {
            count++
            if count == 1 && (string(event.Data["delta"]) != `"你好"` || string(event.Data["native_number"]) != "9007199254740993") { t.Fatal("lost native data") }
            return nil
        })
        if err != nil || count != 2 || !body.closed { t.Fatalf("framing %q: count=%d err=%v closed=%v", newline, count, err, body.closed) }
    }
}

func TestTerminalDoesNotWaitForEOF(t *testing.T) {
    for _, kind := range []string{"response.completed", "response.failed", "response.incomplete", "response.cancelled", "error"} {
        reader, writer := io.Pipe()
        done := make(chan error, 1)
        go func() { done <- ReadResponsesStream(context.Background(), reader, func(FelorxResponseStreamEvent) error { return nil }) }()
        _, err := io.WriteString(writer, "data: {\"type\":\""+kind+"\"}\n\n")
        if err != nil { t.Fatal(err) }
        select { case err := <-done: if err != nil { t.Fatal(err) }; case <-time.After(time.Second): t.Fatal("waited for EOF") }
        writer.Close()
    }
}

func TestCancellationInterruptsRead(t *testing.T) {
    reader, writer := io.Pipe()
    defer writer.Close()
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    done := make(chan error, 1)
    go func() { done <- ReadResponsesStream(ctx, reader, func(FelorxResponseStreamEvent) error { return nil }) }()
    cancel()
    select { case err := <-done: if !errors.Is(err, context.Canceled) { t.Fatal(err) }; case <-time.After(time.Second): t.Fatal("cancellation did not close read") }
}

func TestInvalidStreams(t *testing.T) {
    for _, input := range []string{
        "", "data: [DONE]\n\n", "data: {}\n\n", "data: []\n\n",
        "data: {\"type\":\"response.created\"}\n\n",
        "event: response.created\ndata: {\"type\":\"response.completed\"}\n\n",
        "data: {\"type\":\"response.completed\",\"x\":\"\xff\"}\n\n",
        ":"+strings.Repeat("x", 8*1024*1024)+"\n\n",
    } {
        body := &tinyBody{input: strings.NewReader(input)}
        if err := ReadResponsesStream(context.Background(), body, func(FelorxResponseStreamEvent) error { return nil }); err == nil { t.Fatal("accepted malformed stream") }
        if !body.closed { t.Fatal("body not closed") }
    }
}

func TestSinkStopsStream(t *testing.T) {
    stop := errors.New("consumer stopped")
    body := &tinyBody{input: strings.NewReader("data: {\"type\":\"response.created\"}\n\n")}
    err := ReadResponsesStream(context.Background(), body, func(FelorxResponseStreamEvent) error { return stop })
    if !errors.Is(err, stop) || !body.closed { t.Fatalf("sink stop: %v", err) }
}
