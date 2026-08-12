package main

import "testing"

// The port lives in `hooks.json` rather than in this binary because that file is
// inside the plugin tree the release packager sweeps, swapping every `4004` to
// `4003`. A constant here would sit outside that sweep and silently strand
// either the dev harness or the shipped plugin on the wrong port.
func TestParseHookArgsTakesThePortFromTheConfig(t *testing.T) {
	port, endpoint := parseHookArgs([]string{"--port", "4004", "/api/hooks/stop"})

	if port != "4004" {
		t.Errorf("port = %q, want the one hooks.json passed", port)
	}

	if endpoint != "/api/hooks/stop" {
		t.Errorf("endpoint = %q", endpoint)
	}
}

func TestParseHookArgsFallsBackToTheReleasePort(t *testing.T) {
	port, endpoint := parseHookArgs([]string{"/api/hooks/stop"})

	if port != defaultHookPort {
		t.Errorf("port = %q, want %q when the config names none", port, defaultHookPort)
	}

	if endpoint != "/api/hooks/stop" {
		t.Errorf("endpoint = %q", endpoint)
	}
}

// An ad-hoc setup on neither port — the same override the bash router honoured.
func TestParseHookArgsEnvironmentWins(t *testing.T) {
	t.Setenv("CODEMYSPEC_PORT", "4099")

	port, _ := parseHookArgs([]string{"--port", "4004", "/api/hooks/stop"})

	if port != "4099" {
		t.Errorf("port = %q, want the environment to win over the config", port)
	}
}

// A hook with no endpoint must not POST to the server root.
func TestParseHookArgsWithoutAnEndpoint(t *testing.T) {
	_, endpoint := parseHookArgs([]string{"--port", "4004"})

	if endpoint != "" {
		t.Errorf("endpoint = %q, want empty so runHook refuses", endpoint)
	}

	if code := runHook([]string{"--port", "4004"}); code != 2 {
		t.Errorf("runHook = %d, want 2 (usage) rather than posting to the root", code)
	}
}
