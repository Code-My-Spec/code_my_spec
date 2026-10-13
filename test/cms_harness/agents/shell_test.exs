defmodule CmsHarness.Agents.ShellTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Tools.Bash
  alias CmsHarness.Config

  # The CMS probe is this test's own. MIX_ENV is put back as it was; the
  # module is sync, so no async test reads it meanwhile.
  setup do
    mix_env = System.get_env("MIX_ENV")
    System.put_env("CMS_SHELL_TEST_PROBE", "leaked")
    System.put_env("MIX_ENV", "harness")

    on_exit(fn ->
      System.delete_env("CMS_SHELL_TEST_PROBE")
      restore("MIX_ENV", mix_env)
    end)
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  test "an agent's command is run with MIX_ENV and the harness's CMS_ variables unset" do
    unset = Config.scrubbed_env()

    assert {"CMS_SHELL_TEST_PROBE", nil} in unset
    assert {"MIX_ENV", nil} in unset
  end

  test "a routed request honors its explicit deadline and closes its HTTP client" do
    endpoint = CmsHarness.Web.Endpoint
    previous = Application.get_env(:code_my_spec, endpoint)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    Application.put_env(:code_my_spec, endpoint, http: [port: port])

    on_exit(fn ->
      :gen_tcp.close(listener)

      restore_endpoint(endpoint, previous)
    end)

    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        Bash.execute(
          %{"command" => "mix test test/example_test.exs", "timeout" => 1_000},
          %{working_copy_id: "timeout-regression-copy"}
        )
      end)

    {:ok, socket} = :gen_tcp.accept(listener, 5_000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    assert {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
    assert request =~ "/api/harnesses/timeout-regression-copy/analysis/run"
    assert {:ok, {:error, output}} = Task.yield(task, 8_000)
    assert System.monotonic_time(:millisecond) - started < 9_000
    assert output =~ "timed out after 1000ms"
    assert output =~ "Local command subprocess termination confirmed"
    assert output =~ "Server-side analysis outcome is unknown"
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  defp restore_endpoint(endpoint, nil), do: Application.delete_env(:code_my_spec, endpoint)

  defp restore_endpoint(endpoint, previous),
    do: Application.put_env(:code_my_spec, endpoint, previous)

  test "it leaves every other variable alone" do
    names = for {name, nil} <- Config.scrubbed_env(), do: name

    refute "HOME" in names
    refute "PATH" in names
    assert Enum.all?(names, &(&1 == "MIX_ENV" or String.starts_with?(&1, "CMS_")))
  end
end
