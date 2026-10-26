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

  test "long setup deadlines are advertised without changing restricted shell execution" do
    timeout = Bash.input_schema().properties.timeout
    assert timeout.maximum == 3_600_000
    assert timeout.description =~ "1800000"
    assert Bash.description() =~ "dependency installation"

    assert {:ok, output} =
             Bash.execute(%{"command" => "printf ready", "timeout" => 1_800_000}, %{})

    assert output =~ "ready"
  end

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
    assert output =~ "/dashboard-status"
    assert output =~ "/api/harnesses/timeout-regression-copy/analysis/wait"
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "routed output distinguishes analyzer results from HTTP failures" do
    endpoint = CmsHarness.Web.Endpoint
    previous = Application.get_env(:code_my_spec, endpoint)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    Application.put_env(:code_my_spec, endpoint, http: [port: port])

    on_exit(fn ->
      :gen_tcp.close(listener)
      restore_endpoint(endpoint, previous)
    end)

    for {status, analyzer_status, body, curl_status} <- [
          {200, "0", "1 test, 0 failures\n", 0},
          {422, "2", "1 test, 1 failure\n", 22},
          {502, nil, "Analysis request was rejected before dispatch: unmatched topic.", 22}
        ] do
      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          header = analyzer_status_header(analyzer_status)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 #{status} Result\r\n",
              header,
              "x-analysis-guidance: Check Mix test filters; use mix spex for specs.\r\n",
              "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
              body
            ])

          :gen_tcp.close(socket)
        end)

      assert {:ok, output} =
               Bash.execute(
                 %{
                   "command" => "MIX_ENV=test mix test test/example_test.exs",
                   "timeout" => 5_000
                 },
                 %{working_copy_id: "result-regression-copy"}
               )

      Task.await(server, 6_000)
      assert output =~ body
      assert output =~ "Analysis HTTP status: #{status}"
      assert output =~ "Analyzer exit status (blank if unavailable): #{analyzer_status}\n"
      assert output =~ "Analysis guidance: Check Mix test filters; use mix spex for specs."
      assert output =~ "exit code: #{curl_status}"
    end
  end

  defp analyzer_status_header(nil), do: ""
  defp analyzer_status_header(status), do: "x-exit-status: #{status}\r\n"

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
