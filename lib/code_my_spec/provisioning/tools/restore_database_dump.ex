defmodule CodeMySpec.Provisioning.Tools.RestoreDatabaseDump do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Tools.Starter
  alias CodeMySpec.Resources

  @impl true
  def name, do: "restore_database_dump"

  @impl true
  def description do
    """
    Restore a pg_dump -Fc file into an environment's database: the cutover's
    data move from the old host (`Steps.restore_database_dump/4`).

    The dump must already be on the environment's server, under
    /var/backups/cms-postgres (copy it there first). A target that already
    holds rows, as one migrated by a deploy ahead of the cutover does, is
    refused, naming what is there, until `confirm_non_empty` is true. Past
    that gate a pre-restore dump of the target is taken first, the file is
    restored, ownership goes to the app role, and row counts are checked
    against the dump itself.

    Returns when the restore starts; the agent that started it is messaged
    the outcome (rows per table and where the pre-restore dump is), never any
    values.
    """
  end

  @impl true
  def params do
    %{
      environment:
        {:required, {:meta, :string, [description: "Environment name, e.g. \"prod\"."]}},
      dump_path:
        {:required,
         {:meta, :string,
          [
            description:
              "Absolute path of the pg_dump -Fc file on the environment's server, e.g. \"/var/backups/cms-postgres/fly.dump\"."
          ]}},
      confirm_non_empty:
        {:meta, :boolean,
         [
           description:
             "Restore over a database that already holds rows, after the refusal named them. A pre-restore dump is taken first either way."
         ]}
    }
  end

  @impl true
  def call(%{environment: environment, dump_path: dump_path} = params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope = Resources.project_scope(scope, project)
      opts = [confirm_non_empty: Map.get(params, :confirm_non_empty) == true]
      starter = Starter.new(scope, context, "restore (#{environment})")

      scope
      |> start(project, environment, dump_path, opts, starter)
      |> reply(environment, project, context)
    else
      {:error, reason} -> {:error, "Could not start the restore: #{inspect(reason)}"}
    end
  end

  defp start(scope, project, environment, dump_path, opts, starter) do
    run = fn -> Steps.restore_database_dump(scope, environment, dump_path, opts) end

    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true -> spawn_async(project, run, starter)
      _ -> RunLock.with_lock(project.id, run)
    end
  end

  # `RunProvisioningStep`'s handshake: the task claims the project's run lock,
  # then signals, so the caller learns "started" or "already running" at once.
  defp spawn_async(project, run, starter) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        project.id
        |> RunLock.with_lock(
          fn ->
            send(parent, {ref, :locked})
            run.()
          end,
          Starter.lock_holder(starter)
        )
        |> case do
          {:error, {:already_running, _}} = refused -> send(parent, {ref, refused})
          finished -> Starter.tell(starter, outcome(finished, project.name))
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp outcome({:ok, %{rows: rows, pre_restore_dump: dump}}, name),
    do:
      "The restore for #{name} finished: #{map_size(rows)} tables, #{Enum.sum(Map.values(rows))} rows, " <>
        "matching the dump. Pre-restore dump: #{dump}."

  defp outcome({:error, reason}, name),
    do: "The restore for #{name} stopped: #{format(reason)}"

  defp reply({:ok, :started}, environment, project, context),
    do:
      {:ok,
       "restore (#{environment}) for #{project.name} started — #{Starter.then_what(context[:agent_id])}"}

  defp reply({:ok, %{rows: _} = result}, _environment, project, _context),
    do: {:ok, outcome({:ok, result}, project.name)}

  defp reply({:error, {:already_running, _}}, _environment, _project, _context),
    do: {:error, "a setup run is already in progress for this project — call devops_status"}

  defp reply({:error, reason}, _environment, project, _context),
    do: {:error, outcome({:error, reason}, project.name)}

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
