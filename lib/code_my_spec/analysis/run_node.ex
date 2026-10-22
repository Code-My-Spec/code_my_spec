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

  @doc """
  What a run needs in its environment to join this node.

  The run's BEAM is distributed from boot (`ELIXIR_ERL_OPTIONS`), never by the
  formatter starting distribution itself: `mix test` is still requiring test
  files in parallel then, and a process minted as `nonode@nohost` reads as a
  foreign pid once the node gets a name ("no connection to nonode@nohost",
  issue 8b863c74).
  """
  @spec env(integer(), module()) :: [{String.t(), String.t()}]
  def env(run_id, listener) do
    cookie = Atom.to_string(Node.get_cookie())
    name = "cms_run_#{run_id}_#{System.unique_integer([:positive])}@127.0.0.1"

    [
      # Hidden, so the run shares no `:global` with this node or any other
      # run: globally registered test processes (`Mox.Server`) collided
      # across runs and took the harness down.
      {"ELIXIR_ERL_OPTIONS", "-hidden -name #{name} -setcookie #{cookie}"},
      {"CMS_HARNESS_NODE", Atom.to_string(node())},
      {"CMS_HARNESS_COOKIE", cookie},
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
