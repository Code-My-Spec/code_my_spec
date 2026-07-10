defmodule CodeMySpec.Analysis.Supervisor do
  @moduledoc """
  Supervision subtree for the analysis run service.

  Started only by the local (`cms server`) application — the web build
  compiles the schemas but never runs analyzers. At boot, `:running` ledger
  rows left behind by a dead server process are closed out as `:failed`
  (their ProjectServers died with the previous BEAM; nothing will finish
  them).
  """

  use Supervisor

  alias CodeMySpec.Analysis.RunsRepository

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        {Registry, keys: :unique, name: CodeMySpec.Analysis.Registry},
        {Task.Supervisor, name: CodeMySpec.Analysis.TaskSupervisor},
        {DynamicSupervisor, name: CodeMySpec.Analysis.ServerSupervisor, strategy: :one_for_one}
      ] ++ boot_cleanup()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Stranded-run cleanup only makes sense where runs actually execute async.
  # In `:inline` mode (tests) runs finish in the caller process — and the boot
  # task would just crash against the ExUnit sandbox.
  defp boot_cleanup do
    case Application.get_env(:code_my_spec, :analysis_mode, :async) do
      :inline ->
        []

      _ ->
        [
          Supervisor.child_spec(
            {Task, fn -> RunsRepository.fail_stranded_runs() end},
            id: :fail_stranded_runs,
            restart: :temporary
          )
        ]
    end
  end
end
