defmodule CmsHarness.Setup do
  @moduledoc """
  Explicit, recorded machine setup. Reads never execute commands.

  Each run retains its own results file. Reopening or checking the same run
  preserves completed and failed attempts; `new_run/1` explicitly starts
  another. This context does not create requirements-graph work.
  """

  alias CmsHarness.Setup.{Prerequisites, Step, Store}

  @spec status(keyword()) :: {:ok, map()} | :none | {:error, term()}
  def status(opts \\ []), do: Store.load(directory(opts))

  @spec new_run(keyword()) :: {:ok, map()} | {:error, term()}
  def new_run(opts \\ []) do
    locked(opts, fn directory ->
      case Store.load(directory) do
        {:error, _} = error -> error
        _previous -> create_run(directory, opts)
      end
    end)
  end

  @spec check_prerequisites(keyword()) :: {:ok, map()} | {:error, term()}
  def check_prerequisites(opts \\ []) do
    locked(opts, fn directory ->
      with {:ok, snapshot} <- existing_or_new(directory, opts) do
        run_steps(snapshot, directory, opts)
      end
    end)
  end

  @spec prerequisites_passed?(map()) :: boolean()
  def prerequisites_passed?(%{"steps" => steps}) when is_list(steps) do
    Enum.all?(Prerequisites.keys(), fn key ->
      Enum.any?(steps, &match?(%{"key" => ^key, "state" => "done"}, &1))
    end)
  end

  def prerequisites_passed?(_snapshot), do: false

  @spec generate_project(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_project(path, app, opts) when is_binary(path) and is_binary(app) do
    request = %{"path" => Path.expand(path), "app" => app}

    project_operation("generate", request, opts, fn ->
      CmsHarness.Setup.Project.generate(path, app)
    end)
  end

  @spec connect_project(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_project(path, identity, opts) when is_binary(path) and is_map(identity) do
    with {:ok, root} <- CmsHarness.Setup.Project.validate(path) do
      request = %{"path" => root, "identity" => json_map(identity)}

      project_operation("connect", request, opts, fn ->
        CmsHarness.Setup.Connection.connect(root, identity)
      end)
    end
  end

  defp project_operation(key, request, opts, execute) do
    locked(opts, fn directory ->
      with {:ok, snapshot} <- Store.load(directory),
           true <- prerequisites_passed?(snapshot) do
        previous = snapshot |> Map.get("operations", %{}) |> Map.get(key)
        perform_operation(previous, key, request, snapshot, directory, opts, execute)
      else
        :none -> {:error, :prerequisites_not_checked}
        false -> {:error, :prerequisites_failed}
        {:error, _} = error -> error
      end
    end)
  end

  defp perform_operation(
         %{"state" => "done", "request" => request},
         _key,
         request,
         snapshot,
         _directory,
         _opts,
         _execute
       ),
       do: {:ok, snapshot}

  defp perform_operation(previous, _key, _request, _snapshot, _directory, _opts, _execute)
       when is_map(previous), do: {:error, :operation_already_attempted_start_new_run}

  defp perform_operation(nil, key, request, snapshot, directory, opts, execute) do
    operation = %{
      "state" => "running",
      "request" => request,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "finished_at" => nil
    }

    with {:ok, started} <- persist_operation(directory, snapshot, key, operation, opts) do
      finish_operation(execute.(), directory, started, key, operation, opts)
    end
  end

  defp finish_operation({:ok, result}, directory, snapshot, key, operation, opts) do
    completed =
      Map.merge(operation, %{
        "state" => "done",
        "result" => json_map(result),
        "finished_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    persist_operation(directory, snapshot, key, completed, opts)
  end

  defp finish_operation({:error, reason}, directory, snapshot, key, operation, opts) do
    failed =
      Map.merge(operation, %{
        "state" => "errored",
        "error" => inspect(reason),
        "finished_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    with {:ok, _recorded} <- persist_operation(directory, snapshot, key, failed, opts) do
      {:error, reason}
    end
  end

  defp persist_operation(directory, snapshot, key, operation, opts) do
    operations = snapshot |> Map.get("operations", %{}) |> Map.put(key, operation)
    persist(directory, Map.put(snapshot, "operations", operations), opts)
  end

  @doc "Returns the recorded project and results for the cockpit without rerunning setup."
  @spec handoff(keyword()) :: {:ok, map()} | {:error, term()}
  def handoff(opts) do
    with {:ok, snapshot} <- status(opts),
         true <- prerequisites_passed?(snapshot) do
      handoff_from(snapshot)
    else
      :none -> {:error, :prerequisites_not_checked}
      false -> {:error, :prerequisites_failed}
      {:error, _} = error -> error
    end
  end

  defp handoff_from(%{
         "operations" => %{
           "connect" => %{
             "state" => "done",
             "result" => %{"id" => project_id, "working_copy_id" => copy_id, "root" => root}
           }
         },
         "results_path" => results_path,
         "run_id" => run_id
       })
       when is_binary(project_id) and is_binary(copy_id) and is_binary(root) do
    {:ok,
     %{
       project_id: project_id,
       working_copy_id: copy_id,
       root: root,
       results_path: results_path,
       run_id: run_id
     }}
  end

  defp handoff_from(_snapshot), do: {:error, :project_not_connected}

  defp existing_or_new(directory, opts) do
    case Store.load(directory) do
      :none -> create_run(directory, opts)
      result -> result
    end
  end

  defp create_run(directory, opts) do
    run_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    steps =
      Prerequisites.keys()
      |> Enum.with_index()
      |> Enum.map(fn {key, index} ->
        key |> Step.new(index) |> json_map()
      end)

    snapshot = %{
      "version" => 1,
      "run_id" => run_id,
      "state" => "not_started",
      "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "finished_at" => nil,
      "steps" => steps,
      "results_path" => Store.results_path(directory, run_id)
    }

    persist(directory, snapshot, opts)
  end

  defp run_steps(snapshot, directory, opts) do
    result =
      Enum.reduce_while(snapshot["steps"], {:ok, snapshot}, fn step, {:ok, current} ->
        case run_step(step, current, directory, opts) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, checked} <- result do
      finish_checks(checked, directory, opts)
    end
  end

  defp run_step(
         %{"state" => "not_started", "key" => key, "position" => position},
         snapshot,
         directory,
         opts
       ) do
    running = key |> Step.new(position) |> Step.start(DateTime.utc_now())

    with {:ok, started} <- persist_step(directory, snapshot, running, opts) do
      completed = Prerequisites.run(running, directory)
      persist_step(directory, started, completed, opts)
    end
  end

  defp run_step(%{"state" => "running"} = interrupted, snapshot, directory, opts) do
    recorded =
      Map.merge(interrupted, %{
        "state" => "errored",
        "error" =>
          "The previous check was interrupted; explicitly start a new setup run to retry",
        "finished_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    persist(directory, replace_step(snapshot, recorded), opts)
  end

  defp run_step(_recorded, snapshot, _directory, _opts), do: {:ok, snapshot}

  defp finish_checks(%{"finished_at" => finished} = snapshot, _directory, _opts)
       when is_binary(finished), do: {:ok, snapshot}

  defp finish_checks(snapshot, directory, opts) do
    state = if prerequisites_passed?(snapshot), do: "done", else: "errored"

    completed =
      Map.merge(snapshot, %{
        "state" => state,
        "finished_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    persist(directory, completed, opts)
  end

  defp persist_step(directory, snapshot, step, opts) do
    updated = snapshot |> replace_step(json_map(step)) |> Map.put("state", "running")
    persist(directory, updated, opts)
  end

  defp replace_step(snapshot, %{"key" => key} = recorded) do
    Map.update!(snapshot, "steps", fn steps ->
      Enum.map(steps, fn
        %{"key" => ^key} -> recorded
        other -> other
      end)
    end)
  end

  defp persist(directory, snapshot, opts) do
    with :ok <- Store.save(directory, snapshot) do
      notify(Keyword.get(opts, :notify), snapshot)
      {:ok, snapshot}
    end
  end

  defp notify(nil, _snapshot), do: :ok
  defp notify(pid, snapshot) when is_pid(pid), do: send(pid, {:machine_setup, snapshot})

  defp locked(opts, operation) do
    directory = directory(opts)

    case :global.trans(
           {{__MODULE__, directory}, self()},
           fn -> operation.(directory) end,
           [node()],
           0
         ) do
      :aborted -> {:error, :setup_busy}
      result -> result
    end
  end

  defp directory(opts), do: opts |> Keyword.get(:directory, Store.directory()) |> Path.expand()
  defp json_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
