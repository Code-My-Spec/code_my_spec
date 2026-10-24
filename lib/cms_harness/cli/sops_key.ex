defmodule CmsHarness.Cli.SopsKey do
  @moduledoc """
  `cms sops-key`: the client half of story 1132's key handoff.

  `sops` runs this as a subprocess whenever `SOPS_AGE_KEY_CMD=cms sops-key`
  is set and it needs an age identity — connecting to this box's already-
  running harness over its sops key socket (`CmsHarness.SopsKeySocket`),
  reporting its own pid and uid, and printing whatever key the harness
  answers with to stdout and nothing else, so `sops` can read it directly
  as an age identity file.

  A brand-new, one-shot BEAM boot per invocation, the same shape as `cms
  migrate` (`CmsHarness.Migrate`): there is no persistent process of its
  own to reach for, only the already-running harness it connects out to.
  Exits nonzero — printing nothing to stdout — whenever the harness holds
  no key, is not running at all, or refuses the request.
  """

  @doc "Whether this boot is `cms sops-key`."
  @spec command?([String.t()]) :: boolean()
  def command?(argv), do: "sops-key" in Enum.reject(argv, &(&1 in ["--", ""]))

  @doc "Ask the harness for the key, print it (or the refusal), halt. Never returns."
  @spec start(any()) :: {:ok, pid()}
  def start(_argv) do
    {:ok, pid} = Task.start(fn -> :ok end)
    request() |> report()
    {:ok, pid}
  end

  defp request do
    socket_path = CmsHarness.SopsKeySocket.path()

    with {:ok, sock} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.connect(sock, %{family: :local, path: socket_path}),
         :ok <- :socket.send(sock, "#{System.pid()} #{uid()}\n") do
      result = recv_all(sock)
      :socket.close(sock)
      with {:ok, body} <- result, do: parse(body)
    else
      {:error, reason} -> {:error, connect_error(reason)}
    end
  end

  defp connect_error(:enoent), do: "the harness is not running on this box (no key socket)"
  defp connect_error(reason), do: "could not reach the harness: #{inspect(reason)}"

  defp recv_all(sock, acc \\ "") do
    case :socket.recv(sock, 0, 2_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, :timeout} -> {:ok, acc}
      {:error, reason} -> {:error, "the harness did not answer: #{inspect(reason)}"}
    end
  end

  defp uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "-1"
    end
  end

  defp parse("OK\n" <> rest), do: {:ok, rest}
  defp parse("ERR " <> rest), do: {:error, String.trim(rest)}
  defp parse(other), do: {:error, "unexpected response from the harness: #{inspect(other)}"}

  defp report({:ok, keys}) do
    IO.write(keys)
    System.halt(0)
  end

  defp report({:error, reason}) do
    IO.puts(:stderr, "cms sops-key: #{reason}")
    System.halt(1)
  end
end
