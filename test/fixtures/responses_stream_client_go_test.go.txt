package felorx

import (
    "context"
    "io"
    "net/http"
    "net/http/httptest"
    "net/url"
    "testing"
)

type streamClientTransport struct { calls int }
func (t *streamClientTransport) RoundTrip(r *http.Request) (*http.Response, error) {
    t.calls++
    return http.DefaultTransport.RoundTrip(r)
}

func TestFelorxResponseStreamClient(t *testing.T) {
    for _, legacy := range []bool{false, true} {
        for _, contextToken := range []bool{false, true} {
            path, operation := "/api/ai/v1/responses", "ResponsesAPIService.CreateResponse"
            if legacy { path, operation = "/api/ai/openai/responses", "ResponsesAPIService.CreateResponseLegacy" }
            server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                if r.URL.Path != "/root"+path { t.Errorf("path: %s", r.URL.Path) }
                if r.Header.Get("Authorization") != "Bearer selected-token" || len(r.Header.Values("Authorization")) != 1 { t.Error("auth config not reused") }
                if r.Header.Get("X-Felorx-Ai-Provider") != "selected-provider" || r.Header.Get("X-Test") != "default-header" || r.Header.Get("User-Agent") != "stream-fixture" { t.Error("headers not reused") }
                w.Header().Set("Content-Type", "text/event-stream")
                io.WriteString(w, "data: {\"type\":\"response.completed\"}\n\n")
            }))
            transport := &streamClientTransport{}
            cfg := NewConfiguration()
            cfg.Servers = ServerConfigurations{{URL:"https://wrong-default.invalid"}}
            cfg.OperationServers[operation] = ServerConfigurations{{URL:"https://wrong-operation.invalid/root"}}
            address, _ := url.Parse(server.URL)
            cfg.Host, cfg.Scheme = address.Host, address.Scheme
            cfg.HTTPClient = &http.Client{Transport:transport}
            cfg.UserAgent = "stream-fixture"
            cfg.DefaultHeader["X-Test"] = "default-header"
            cfg.DefaultHeader["Authorization"] = "Bearer selected-token"
            cfg.DefaultHeader["X-Felorx-Ai-Provider"] = "selected-provider"
            ctx := context.Background()
            provider := ""
            if contextToken {
                cfg.DefaultHeader["Authorization"] = "Bearer superseded-token"
                cfg.DefaultHeader["X-Felorx-Ai-Provider"] = "superseded-provider"
                ctx = context.WithValue(ctx, contextKey("accesstoken"), "selected-token")
                provider = "selected-provider"
            }
            client := NewAPIClient(cfg)
            count := 0
            emit := func(FelorxResponseStreamEvent) error { count++; return nil }
            var err error
            if legacy { err = client.CreateResponseLegacyRawStream(ctx, map[string]interface{}{"input":"hello"}, provider, emit) } else {
                err = client.CreateResponseRawStream(ctx, map[string]interface{}{"input":"hello"}, provider, emit)
            }
            server.Close()
            if err != nil || count != 1 || transport.calls != 1 { t.Fatalf("client stream: %v count=%d transport=%d", err, count, transport.calls) }
        }
    }
}
