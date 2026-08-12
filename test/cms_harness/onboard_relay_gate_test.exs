defmodule CmsHarness.OnboardRelayGateTest do
  @moduledoc """
  Onboarding installs hooks that are run by `cms-mcp-relay hook …`, so it
  refuses to install them against a relay that has no `hook` subcommand.

  The failure it prevents is the quiet kind. An old relay does not reject the
  argument — `hook` is not a flag it knows, so it falls through to the MCP
  path, posts the hook payload to /mcp?dir=, takes the JSON-RPC parse error it
  gets back, and exits 0. Claude Code reads 0 as a hook that ran. Eight hooks
  go dead with no error on either side, and the only symptom is that everything
  the harness was supposed to decide stops happening.

  Both binaries exit 0, so the exit status cannot be the signal. The marker on
  stdout is, and an old binary cannot print it: it has no `capabilities` branch
  either, and relays stdin instead.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.Harness.Onboard

  setup do
    dir = Path.join(System.tmp_dir!(), "relay-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp fake(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  test "accepts a relay that reports the capability", %{dir: dir} do
    relay = fake(dir, "current", ~s|echo "cms-mcp-relay hooks=1"|)
    assert Onboard.capable?(relay)
  end

  test "rejects the old relay's behaviour: silent, and exit 0", %{dir: dir} do
    # What the installed 1.8.2 binary does with an argument it does not know —
    # relays stdin, which with stdin closed is an immediate EOF, and succeeds.
    relay = fake(dir, "old", "cat > /dev/null; exit 0")
    refute Onboard.capable?(relay)
  end

  test "rejects a relay that prints something else entirely", %{dir: dir} do
    relay = fake(dir, "chatty", ~s|echo "usage: cms-mcp-relay [flags]"|)
    refute Onboard.capable?(relay)
  end

  test "rejects a relay that fails", %{dir: dir} do
    relay = fake(dir, "broken", ~s|echo "cms-mcp-relay hooks=1"; exit 1|)

    refute Onboard.capable?(relay),
           "a relay that reports the capability while failing has not demonstrated it"
  end

  test "does not hang on a relay that blocks", %{dir: dir} do
    relay = fake(dir, "hanging", "sleep 120")

    {us, result} = :timer.tc(fn -> Onboard.capable?(relay) end)

    refute result

    assert us < 30_000_000,
           "the probe has to give up — a check that hangs becomes an onboarding that hangs"
  end
end
