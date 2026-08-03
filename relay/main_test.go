package main

import "testing"

// What reaches stdout is the whole contract with Claude Code: it validates every
// line as a JSON-RPC message and closes the transport on the first one that is
// not. A dropped line costs one call; a bad line costs the session, and presents
// as a plugin with no tools rather than as a protocol error.

func TestIsNotification(t *testing.T) {
	cases := []struct {
		name string
		msg  string
		want bool
	}{
		{
			// The one that did the damage. The server answers this with 202 and a
			// body of `{}`, which is not a JSON-RPC message.
			name: "initialized notification",
			msg:  `{"jsonrpc":"2.0","method":"notifications/initialized"}`,
			want: true,
		},
		{
			name: "notification with params",
			msg:  `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}`,
			want: true,
		},
		{
			name: "request with an id expects a reply",
			msg:  `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
			want: false,
		},
		{
			// A string id is legal JSON-RPC and must not be read as absent.
			name: "string id is still an id",
			msg:  `{"jsonrpc":"2.0","id":"abc","method":"tools/list"}`,
			want: false,
		},
		{
			// id: 0 is a real id. A naive check on a zero value would call this a
			// notification and swallow a reply the client is waiting on.
			name: "zero id is an id",
			msg:  `{"jsonrpc":"2.0","id":0,"method":"tools/list"}`,
			want: false,
		},
		{
			name: "unparseable is forwarded and left to the server",
			msg:  `not json at all`,
			want: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := isNotification(c.msg); got != c.want {
				t.Errorf("isNotification(%s) = %v, want %v", c.msg, got, c.want)
			}
		})
	}
}

func TestIsJSONRPC(t *testing.T) {
	cases := []struct {
		name string
		msg  string
		want bool
	}{
		{
			// Exactly what a 202 to a notification carries, and exactly what took
			// the transport down.
			name: "empty object",
			msg:  `{}`,
			want: false,
		},
		{name: "result", msg: `{"jsonrpc":"2.0","id":1,"result":{}}`, want: true},
		{name: "error", msg: `{"jsonrpc":"2.0","id":1,"error":{"code":-32600}}`, want: true},
		{name: "batch", msg: `[{"jsonrpc":"2.0","id":1,"result":{}}]`, want: true},
		{name: "empty batch", msg: `[]`, want: false},
		{name: "html error page", msg: `<html><body>404</body></html>`, want: false},
		{name: "bare string", msg: `"ok"`, want: false},
		{
			// A plain JSON object without the version is not a JSON-RPC message,
			// however plausible it looks.
			name: "object missing jsonrpc",
			msg:  `{"id":1,"result":{}}`,
			want: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := isJSONRPC(c.msg); got != c.want {
				t.Errorf("isJSONRPC(%s) = %v, want %v", c.msg, got, c.want)
			}
		})
	}
}
