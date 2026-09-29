defmodule CmsHarness.AppInstance.Runner.LocalTunnelBaseDirTest do
  @moduledoc """
  2026-09-29 incident: `ClientUtils.CloudflareTunnel` defaults its config
  directory to `Path.join(File.cwd!(), "tmp/cloudflared")` — correct for an
  app writing its own tunnel's files from inside its own checkout, wrong for
  the harness, which is one BEAM serving every project it is asked about.
  Without an explicit `base_dir`, the harness wrote metric_flow's tunnel
  config into code_my_spec's own checkout (wherever the harness process
  happened to be running from), overwriting code_my_spec's own
  `config.yml`/`credentials.json` on disk.

  This is the one property that incident needs guaranteed: whatever
  `tunnel_base_dir/1` returns is never CWD-relative and never lands inside
  any checkout, for any working directory the harness might be running
  from.
  """

  # Not async: exercises File.cd!/2, which changes this OS process's actual
  # working directory (restored afterward, but briefly visible to any other
  # process reading it) — never safe to race against sibling tests that
  # might read cwd concurrently.
  use ExUnit.Case, async: false

  alias CmsHarness.AppInstance.Runner.Local

  test "never depends on the current working directory" do
    tunnel_id = "6227e617-example"

    File.cd!(System.tmp_dir!(), fn ->
      from_tmp = Local.tunnel_base_dir(tunnel_id)
      from_home = File.cd!(System.user_home!(), fn -> Local.tunnel_base_dir(tunnel_id) end)

      assert from_tmp == from_home,
             "tunnel_base_dir/1 answered differently depending on cwd — it must not " <>
               "read File.cwd!() at all, the exact bug that let one project's tunnel " <>
               "files land inside another project's checkout"
    end)
  end

  test "never lands inside a checkout — always under this machine's own harness state" do
    checkout_roots = [Path.expand("."), System.tmp_dir!()]

    for root <- checkout_roots do
      dir = File.cd!(root, fn -> Local.tunnel_base_dir("6227e617-example") end)

      refute String.starts_with?(dir, root),
             "tunnel_base_dir/1 answered a path under #{root} — a harness-owned tunnel " <>
               "directory must never sit inside any checkout it happens to be running from"

      assert String.starts_with?(dir, Path.join(System.user_home!(), ".codemyspec")),
             "expected a path under ~/.codemyspec, got #{dir}"
    end
  end

  test "one directory per tunnel — two tunnels never collide" do
    a = Local.tunnel_base_dir("tunnel-a")
    b = Local.tunnel_base_dir("tunnel-b")

    refute a == b, "two different tunnels answered the same directory"
  end
end
