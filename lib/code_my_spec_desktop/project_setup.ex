defmodule CodeMySpecDesktop.ProjectSetup do
  @moduledoc "Desktop setup jobs backed by the shared recorded setup workflow."
  use GenServer
  alias CodeMySpec.{Agents, Devices, Paths, Projects, WorkingCopies}
  alias CmsHarness.{HarnessConfig, ProjectIdentity, Setup}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run(scope, project, action, app),
    do: GenServer.call(__MODULE__, {:run, scope, project, action, app})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:run, scope, project, action, app}, _from, jobs) do
    job = Map.get(jobs, project.id, %{running: false})

    cond do
      action == "status" ->
        {:reply, {:ok, status(project, job)}, jobs}

      action not in ~w(check prepare_database create connect refresh) ->
        {:reply, {:error, "Unknown setup action."}, jobs}

      Enum.any?(jobs, fn {_, job} -> job.running end) ->
        {:reply, {:error, :device_setup_already_running}, jobs}

      true ->
        task =
          Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fn ->
            execute(scope, project, action, app)
          end)

        job = %{running: true, action: action, ref: task.ref}
        {:reply, {:ok, status(project, job)}, Map.put(jobs, project.id, job)}
    end
  end

  @impl true
  def handle_info({ref, result}, jobs) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(jobs, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, jobs),
    do: {:noreply, finish(jobs, ref, {:error, inspect(reason)})}

  defp finish(jobs, ref, result) do
    Map.new(jobs, fn {id, job} ->
      if job[:ref] == ref do
        Setup.record_job(id, %{action: job.action, result: result_data(result)})

        {id,
         job
         |> Map.delete(:ref)
         |> Map.put(:running, false)
         |> Map.put(:result, result_data(result))}
      else
        {id, job}
      end
    end)
  end

  defp result_data({:ok, data}) when is_map(data),
    do: %{
      "ok" => true,
      "ready" => Map.get(data, :ready, false),
      "prerequisites_passed" => Map.get(data, :prerequisites_passed),
      "commands" => Map.get(data, :commands),
      "database_role_created" => Map.get(data, :created?)
    }

  defp result_data({:error, %{commands: commands, error: reason}}),
    do: %{"ok" => false, "error" => reason, "commands" => commands}

  defp result_data({:error, reason}), do: %{"ok" => false, "error" => inspect(reason)}
  defp result_data(other), do: %{"ok" => false, "error" => inspect(other)}

  defp status(project, job) do
    snapshot =
      case Setup.status(options(project)) do
        {:ok, snapshot} -> snapshot
        :none -> nil
        {:error, reason} -> %{error: inspect(reason)}
      end

    job = Map.merge(%{result: snapshot && get_in(snapshot, ["job", "result"])}, job)

    job
    |> Map.delete(:ref)
    |> Map.merge(%{
      device_id: CmsHarness.Device.recorded_id(),
      machine_snapshot: machine_snapshot(),
      project_id: project.id,
      directory: directory(project),
      prerequisite_catalog: Setup.Prerequisites.keys(),
      snapshot: snapshot
    })
  end

  defp machine_snapshot do
    case Setup.status() do
      {:ok, snapshot} -> snapshot
      _ -> nil
    end
  end

  def directory(project),
    do:
      Paths.expand(
        project.onboarding.destination_path || project.local_path || Paths.project_home(project)
      )

  defp options(project), do: Setup.project_options(project.id)

  @doc false
  def execute(scope, project, action, app) do
    opts = options(project)
    scope = %{scope | active_project: project, active_project_id: project.id}
    app = app || Macro.underscore(project.module_name || "app") |> String.replace("/", "_")

    case action do
      "prepare_database" ->
        CmsHarness.Setup.Database.prepare(Paths.local_state_dir())

      "check" ->
        check_machine(project)

      "create" ->
        with :new <- project.onboarding.starting_point,
             {:ok, checked} <- check([]),
             true <- Setup.prerequisites_passed?(checked),
             {:ok, _} <- Setup.use_machine_checks(project.id, checked),
             {:ok, _} <- Setup.generate_project(directory(project), app, opts) do
          connect(scope, project, app, opts)
        else
          false -> {:error, :prerequisites_failed}
          :existing -> {:error, :use_connect_for_existing_project}
          nil -> {:error, :save_starting_point_first}
          other -> other
        end

      "connect" ->
        connect(scope, project, app, opts)

      "refresh" ->
        with {:ok, snapshot} <- Setup.refresh_connection(opts) do
          ready(scope, snapshot)
        end
    end
  end

  defp check_machine(project) do
    with {:ok, _} <- Setup.new_run(),
         {:ok, checked} <- Setup.check_prerequisites(),
         {:ok, _} <- Setup.use_machine_checks(project.id, checked) do
      if Setup.prerequisites_passed?(checked),
        do: {:ok, %{prerequisites_passed: true}},
        else: {:error, :prerequisites_failed}
    end
  end

  defp check(opts) do
    # Failed checks are retried in a new recorded run before any project operation.
    with {:ok, _} <- maybe_reset_checks(opts), do: Setup.check_prerequisites(opts)
  end

  defp maybe_reset_checks(opts) do
    case Setup.status(opts) do
      {:ok, %{"state" => "errored"} = snapshot} ->
        if Map.get(snapshot, "operations", %{}) == %{},
          do: Setup.new_run(opts),
          else: {:ok, snapshot}

      :none ->
        Setup.new_run(opts)

      result ->
        result
    end
  end

  defp connect(scope, project, app, opts) do
    with {:ok, machine} <- Setup.status(),
         true <- Setup.prerequisites_passed?(machine),
         {:ok, _} <- Setup.use_machine_checks(project.id, machine),
         {:ok, copy} <-
           register_checkout(scope, directory(project), CmsHarness.Device.recorded_id()),
         {:ok, snapshot} <-
           Setup.connect_project(
             directory(project),
             %{project_id: project.id, working_copy_id: copy.id, app: app},
             opts
           ) do
      ready(scope, snapshot)
    else
      false -> {:error, :prerequisites_failed}
      :none -> {:error, :run_check_first}
      error -> error
    end
  end

  @doc false
  def register_checkout(scope, root, device_id) do
    with {:ok, project} <- Projects.Onboarding.fetch(scope),
         true <- is_binary(device_id) and device_id != "",
         {:ok, root} <- Setup.Project.validate(root),
         :ok <- same_project(root, project.id),
         {:ok, config} <- checkout_config(root),
         :ok <- same_server(config),
         :ok <- same_copy(config, project.id, root),
         :ok <- compatible_main(scope, root),
         {:ok, device} <- Devices.announce(scope, device_id, %{kind: :local}),
         {:ok, copy} <-
           WorkingCopies.issue(scope, checkout_id(scope, config), device: device.id, root: root),
         {:ok, copy} <- WorkingCopies.report_root(copy, root),
         :ok <-
           HarnessConfig.write(root, %{
             project_id: project.id,
             working_copy_id: copy.id,
             server_url: CmsHarness.Config.server_url()
           }),
         {:ok, copy} <- WorkingCopies.designate_main(scope, copy.id),
         {:ok, _} <- Projects.update_project(scope, project, %{local_path: root}) do
      {:ok, copy}
    else
      false -> {:error, :device_identity_unavailable}
      error -> error
    end
  end

  defp checkout_id(scope, config) do
    config[:working_copy_id] ||
      case WorkingCopies.main(scope) do
        nil -> nil
        copy -> copy.id
      end
  end

  defp same_project(root, id) do
    case ProjectIdentity.resolve(root) do
      {:ok, %{id: ^id}} -> :ok
      {:error, :no_project_id} -> :ok
      {:ok, %{id: other}} -> {:error, {:project_identity_conflict, other}}
      error -> error
    end
  end

  defp checkout_config(root) do
    case HarnessConfig.read_file(root) do
      :none -> {:ok, %{}}
      result -> result
    end
  end

  defp same_copy(%{working_copy_id: id}, project_id, root) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{project_id: ^project_id, root: existing}} when existing in [nil, root] -> :ok
      {:error, :not_found} -> :ok
      _ -> {:error, :working_copy_identity_conflict}
    end
  end

  defp same_copy(_, _, _), do: :ok

  defp same_server(%{server_url: url}) when is_binary(url) do
    if url == CmsHarness.Config.server_url(), do: :ok, else: {:error, :server_identity_conflict}
  end

  defp same_server(_), do: :ok

  defp compatible_main(scope, root) do
    case WorkingCopies.main(scope) do
      nil -> :ok
      %{root: ^root} -> :ok
      _ -> {:error, :main_working_copy_already_exists_elsewhere}
    end
  end

  defp activate_team(scope, snapshot, true) do
    if snapshot["team_activated"] do
      :ok
    else
      with {:ok, _} <- Agents.set_copy_continuous(scope, WorkingCopies.main(scope).id, true),
           :ok <- activate_detached_team(scope),
           {:ok, _} <- Setup.mark_team_activated(scope.active_project_id) do
        :ok
      end
    end
  end

  defp activate_team(_scope, _snapshot, false), do: :ok

  defp activate_detached_team(scope) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(
      &(&1.execution_mode == :detached and &1.role in [:main, :product] and
          is_nil(&1.retired_at) and is_nil(&1.off_at))
    )
    |> Enum.reduce_while(:ok, fn agent, :ok ->
      case Agents.set_agent_continuous(scope, agent.id, true) do
        {:ok, _, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ready(scope, snapshot) do
    connected = get_in(snapshot, ["operations", "connect", "result", "connected"]) == true
    dev_ready = get_in(snapshot, ["operations", "dev_setup", "state"]) == "done"

    if connected do
      connected_ready(scope, snapshot, dev_ready)
    else
      {:ok, %{ready: false, snapshot: snapshot}}
    end
  end

  # Main stays working-copy-less: it names a copy on each read/write/edit/bash
  # (`CodeMySpec.CopyTools`), so setup has nothing to attach it to.
  defp connected_ready(scope, snapshot, dev_ready) do
    with :ok <- activate_team(scope, snapshot, dev_ready) do
      {:ok, %{ready: dev_ready, snapshot: snapshot}}
    end
  end
end
