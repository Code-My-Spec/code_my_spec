defmodule CmsHarness.BrowserConnectionPerCopyTest do
  @moduledoc """
  Every copy holds its own browser session, and all of them can come up at once.

  Every harness boot joins every copy together, and each join asks the browser
  what it offers. With one machine-wide session name, all but one of those
  probes collided on `:already_started` — and because `Anubis.Client.start_link/1`
  links its supervisor to the caller, each loser was killed by the failed start
  rather than handed an error, so every copy but one reported no browser tools.

  `CmsHarnessTest.PerNameMcpTransport` has Anubis's shape and nothing else. No
  subprocess, no vibium.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Browser
  alias CmsHarnessTest.PerNameMcpTransport
  alias CmsHarnessTest.PerNameMcpTransport.Barrier

  @copies 8

  setup do
    prior_transport = Application.get_env(:code_my_spec, :harness_mcp_transport)
    prior_exe = Application.get_env(:code_my_spec, :vibium_executable)
    Application.put_env(:code_my_spec, :harness_mcp_transport, PerNameMcpTransport)
    Application.put_env(:code_my_spec, :vibium_executable, "/usr/bin/true")

    on_exit(fn ->
      put_or_delete(:harness_mcp_transport, prior_transport)
      put_or_delete(:vibium_executable, prior_exe)
    end)

    :ok
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp put_or_delete(key, v), do: Application.put_env(:code_my_spec, key, v)

  defp copies(n) do
    tag = System.unique_integer([:positive])

    for i <- 1..n do
      root = "/copies/#{tag}/copy-#{i}"
      start_supervised!({Browser.Owner, root: root}, id: {:owner, root})
      root
    end
  end

  defp probe_all(roots) do
    roots
    |> Task.async_stream(&Browser.probe/1, timeout: 10_000, max_concurrency: length(roots))
    |> Enum.map(fn {:ok, probe} -> probe end)
  end

  describe "N copies probing at once" do
    setup do
      start_supervised!({Barrier, @copies})
      %{roots: copies(@copies)}
    end

    test "every copy gets the browser's tools", %{roots: roots} do
      probes = probe_all(roots)

      assert Enum.all?(probes, &(&1.status == :ready)), inspect(Enum.map(probes, & &1.status))
      assert Enum.all?(probes, &(&1.names == ["browser_navigate"]))
      assert Barrier.connects() == @copies
    end

    test "each copy holds a connection of its own", %{roots: roots} do
      probe_all(roots)

      clients = Enum.map(roots, &GenServer.whereis(Browser.session(&1)))

      assert Enum.all?(clients, &is_pid/1)
      assert clients |> Enum.uniq() |> length() == @copies

      for {root, client} <- Enum.zip(roots, clients) do
        assert Browser.call(root, "browser_get_url", %{}) == {:ok, inspect(client)},
               "a call for #{root} reached a session that is not its own"
      end
    end

    test "a copy that goes closes its own connection and no other", %{roots: roots} do
      probe_all(roots)
      [gone | staying] = roots

      stop_supervised!({:owner, gone})

      assert GenServer.whereis(Browser.session(gone)) == nil
      assert Enum.all?(staying, &is_pid(GenServer.whereis(Browser.session(&1))))
    end
  end

  describe "one copy asked twice at once" do
    setup do
      start_supervised!({Barrier, 1})
      %{roots: copies(1)}
    end

    test "starts one session and both get it", %{roots: [root]} do
      results =
        [
          fn -> Browser.probe(root).status end,
          fn -> Browser.call(root, "browser_get_url", %{}) end
        ]
        |> Enum.flat_map(&List.duplicate(&1, 4))
        |> Task.async_stream(& &1.(), timeout: 10_000, max_concurrency: 8)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ready)) == 4
      assert Enum.count(results, &match?({:ok, "#PID<" <> _}, &1)) == 4
      assert Barrier.connects() == 1
    end
  end

  test "a copy nothing serves has no session to open" do
    assert %{names: [], status: {:unreachable, reason}} = Browser.probe("/not/served")
    assert reason =~ "not_serving"
  end
end
