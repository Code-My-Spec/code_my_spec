defmodule CodeMySpec.Analysis.RunNode do
  @moduledoc """
  Distribution for the node a test run reports to (story 1141), started on the
  first run at `<prefix>_<os pid>@127.0.0.1`: a node that never runs a suite
  never opens a port.
  """

  require Logger

  @credo_reporter_config ~s(%{configs: [%{name: "default", plugins: [{ClientUtils.CredoReporter, []}]}]})

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
  #
  # The calling process is the run's owner, registered globally as
  # `{:cms_run, run_id}`: the run watches it and halts when it goes — its copy
  # stopping, its harness restarting, or the run being cancelled (story 1142).
  #
  # Hidden, so the run shares no `:global` with this node or any other run:
  # test processes registered globally (`Mox.Server`) collided across runs,
  # and global's conflict resolution killed the harness's own, taking the
  # harness down.
  @spec env(integer(), module()) :: [{String.t(), String.t() | nil}]
  def env(run_id, listener) do
    :yes = :global.re_register_name({:cms_run, run_id}, self())
    cookie = Atom.to_string(Node.get_cookie())
    # The minting BEAM's OS pid as well: run ids come from each database, and
    # concurrent suites in different copies reuse them while every BEAM's
    # counter starts low, so two runs on one machine (one epmd) minted the
    # same name and the second could not boot ("seems to be in use").
    name =
      "cms_run_#{run_id}_#{System.pid()}_#{System.unique_integer([:positive])}@127.0.0.1"

    [
      {"ELIXIR_ERL_OPTIONS", "-hidden -name #{name} -setcookie #{cookie}"},
      {"CMS_HARNESS_NODE", Atom.to_string(node())},
      {"CMS_HARNESS_COOKIE", cookie},
      {"CMS_RUN_ID", Integer.to_string(run_id)},
      {"CMS_RUN_LISTENER", Atom.to_string(listener)},
      # Unset: a run started from inside a shard of another run (a spex
      # driving a fixture's suite) inherited that shard's numbering, reported
      # its exit as shard 2 of 4, and was never finished. `mix cms.spex` sets
      # its own shards' after this.
      {"CMS_RUN_SHARD", nil},
      {"CMS_RUN_SHARDS", nil}
    ]
  end

  @doc """
  `env/2` for a credo run (story 1144): the same link, and Credo told to load
  `ClientUtils.CredoReporter` through `CREDO_EXTRA_CONFIG`, which Credo merges
  into the project's own config. No link, nothing added.
  """
  @spec credo_env([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def credo_env([]), do: []

  def credo_env(link_env),
    do: [{"CREDO_EXTRA_CONFIG", @credo_reporter_config} | link_env]

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
