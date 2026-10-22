defmodule CodeMySpec.Analysis.RunNode do
  @moduledoc """
  Distribution for the node a test run reports to (story 1141), started on the
  first run at `<prefix>_<os pid>@127.0.0.1`: a node that never runs a suite
  never opens a port.
  """

  require Logger

  @doc "Start distribution if this node has none."
  @spec ensure_started(String.t()) :: :ok
  def ensure_started(prefix) do
    if Node.alive?(), do: :ok, else: start(:"#{prefix}_#{System.pid()}@127.0.0.1")
  end

  @doc "What a run needs in its environment to join this node."
  @spec env(integer(), module()) :: [{String.t(), String.t()}]
  def env(run_id, listener) do
    [
      {"CMS_HARNESS_NODE", Atom.to_string(node())},
      {"CMS_HARNESS_COOKIE", Atom.to_string(Node.get_cookie())},
      {"CMS_RUN_ID", Integer.to_string(run_id)},
      {"CMS_RUN_LISTENER", Atom.to_string(listener)}
    ]
  end

  # `Node.start/2` registers with epmd; a machine whose epmd is not running
  # gets one started, once.
  defp start(name) do
    case Node.start(name, :longnames) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Analysis] starting distribution failed (#{inspect(reason)}); starting epmd"
        )

        System.cmd("epmd", ["-daemon"])
        {:ok, _pid} = Node.start(name, :longnames)
        :ok
    end
  end
end
