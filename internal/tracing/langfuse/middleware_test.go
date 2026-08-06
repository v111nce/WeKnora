package langfuse

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Tencent/WeKnora/internal/types"
	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func TestGinMiddlewareAttachesAgentRequestAsChildSpanWithoutOwningTraceFields(t *testing.T) {
	_, exporter := newTestManager(t)
	router := tracedAgentChatRouter()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/agent-chat/weknora-session", nil)
	request.Header.Set("traceparent", "00-4af80102030405060708090a0b0c0de2-0102030405060708-01")
	request.Header.Set("baggage", "ailx-user-id=42,ailx-session-id=1076600000000001")

	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d, want 200", response.Code)
	}

	span := exportedSpanNamed(t, exporter.GetSpans(), "POST /api/v1/agent-chat/:session_id")
	if got := span.SpanContext.TraceID().String(); got != "4af80102030405060708090a0b0c0de2" {
		t.Fatalf("trace id=%s, want upstream Agent trace", got)
	}
	if got := span.Parent.SpanID().String(); got != "0102030405060708" {
		t.Fatalf("parent span id=%s, want upstream Agent generation", got)
	}
	if got := spanAttr(span.Attributes, attrObsType); got != obsTypeSpan {
		t.Fatalf("observation type=%q, want %q", got, obsTypeSpan)
	}
	for _, key := range []string{attrTraceName, attrUserID, attrSessionID, attrTraceInput, attrTraceOutput} {
		if spanHasAttr(span, key) {
			t.Fatalf("WeKnora child span must not own Agent trace attribute %s: %#v", key, span.Attributes)
		}
	}
	metadata := spanAttr(span.Attributes, attrObsMetadata)
	if metadata == "" || !containsAll(metadata, `"weknora.session_id":"weknora-session"`, `"status":200`) {
		t.Fatalf("metadata=%q, want WeKnora correlation and status", metadata)
	}
}

func TestGinMiddlewareKeepsStandaloneWeKnoraIdentityAndOutput(t *testing.T) {
	_, exporter := newTestManager(t)
	router := tracedAgentChatRouter()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/agent-chat/weknora-session", nil)
	request = request.WithContext(context.WithValue(request.Context(), types.UserIDContextKey, "weknora-user"))

	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)

	span := exportedSpanNamed(t, exporter.GetSpans(), "POST /api/v1/agent-chat/:session_id")
	for key, want := range map[string]string{
		attrUserID:    "weknora-user",
		attrSessionID: "weknora-session",
	} {
		if got := spanAttr(span.Attributes, key); got != want {
			t.Fatalf("%s=%q, want %q", key, got, want)
		}
	}
	if !spanHasAttr(span, attrTraceOutput) {
		t.Fatal("standalone WeKnora trace lost its HTTP outcome")
	}
}

func tracedAgentChatRouter() *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(GinMiddleware())
	router.POST("/api/v1/agent-chat/:session_id", func(c *gin.Context) {
		c.Status(http.StatusOK)
	})
	return router
}

func exportedSpanNamed(t *testing.T, spans []tracetest.SpanStub, name string) tracetest.SpanStub {
	t.Helper()
	for _, span := range spans {
		if span.Name == name {
			return span
		}
	}
	t.Fatalf("span %q not exported: %#v", name, spans)
	return tracetest.SpanStub{}
}

func spanHasAttr(span tracetest.SpanStub, key string) bool {
	for _, item := range span.Attributes {
		if string(item.Key) == key {
			return true
		}
	}
	return false
}

func containsAll(value string, parts ...string) bool {
	for _, part := range parts {
		if !strings.Contains(value, part) {
			return false
		}
	}
	return true
}
