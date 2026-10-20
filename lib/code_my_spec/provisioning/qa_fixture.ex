defmodule CodeMySpec.Provisioning.QaFixture do
  @moduledoc """
  Explicitly registered, disposable provider state for browser QA in development.

  This models the provider boundary of the setup runner, not real infrastructure.
  State lasts for this BEAM instance; restarting requires a fresh fixture.
  Ordinary projects never receive these callbacks.
  """
  use GenServer

  @enabled Application.compile_env(:code_my_spec, :dev_routes, false)
  @steps ~w(repository secrets server domain dns tls deploy email inbound storage backups content widget callback_credential monitoring telemetry)

  def register(project_id, account_id) do
    if @enabled do
      with :ok <- ensure_started() do
        GenServer.call(__MODULE__, {:register, project_id, account_id})
      end
    else
      {:error, :disabled}
    end
  end

  def snapshot(project_id), do: request({:snapshot, project_id})

  def control(project_id, step, action, environment \\ nil)

  def control(project_id, step, action, environment)
      when step in @steps and action in ~w(hold release refuse allow delete register) do
    request({:control, project_id, {step, environment}, action})
  end

  def control(_, _, _, _), do: {:error, :invalid_control}

  def options(scope, opts, environment \\ nil) do
    if @enabled do
      case request({:owns, scope.active_project_id, scope.active_account_id}) do
        true ->
          environment = environment || Keyword.get(opts, :environment)

          Keyword.merge(opts,
            environment: environment,
            verify: fn _scope, key ->
              request({:verify, scope.active_project_id, {to_string(key), environment}})
            end,
            execute: fn _scope, key, _opts ->
              request({:execute, scope.active_project_id, {to_string(key), environment}}, 120_000)
            end
          )

        _ ->
          unavailable_fixture_options(scope, opts)
      end
    else
      unavailable_fixture_options(scope, opts)
    end
  end

  defp unavailable_fixture_options(
         %{
           active_project: %{name: "QA Setup " <> _}
         },
         opts
       ) do
    error = {:error, "QA provider fixture is unavailable; create a fresh development fixture."}
    Keyword.merge(opts, verify: fn _, _ -> error end, execute: fn _, _, _ -> error end)
  end

  defp unavailable_fixture_options(_scope, opts), do: opts

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  defp ensure_started do
    child = Supervisor.child_spec({__MODULE__, []}, restart: :temporary)

    case Supervisor.start_child(CodeMySpec.Supervisor, child) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      error -> error
    end
  end

  defp request(message, timeout \\ 5_000) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_registered}
      pid -> GenServer.call(pid, message, timeout)
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, id, account_id}, _from, state) do
    fixture = %{
      account_id: account_id,
      resources: %{},
      modes: %{},
      waiting: %{},
      events: [],
      sequence: 0
    }

    {:reply, :ok, Map.put_new(state, id, fixture)}
  end

  def handle_call({:owns, id, account_id}, _from, state) do
    {:reply, match?(%{account_id: ^account_id}, state[id]), state}
  end

  def handle_call({:snapshot, id}, _from, state) do
    case state[id] do
      nil ->
        {:reply, {:error, :not_registered}, state}

      fixture ->
        snapshot = %{
          simulated: true,
          project_id: id,
          resources: fixture.resources |> Map.values() |> List.flatten(),
          events: Enum.reverse(fixture.events),
          held:
            Enum.map(Map.keys(fixture.waiting), fn {step, env} ->
              %{step: step, environment: env}
            end)
        }

        {:reply, {:ok, snapshot}, state}
    end
  end

  def handle_call({operation, id, key}, from, state) when operation in [:verify, :execute] do
    fixture = Map.fetch!(state, id) |> event(operation, key)
    dispatch(operation, id, key, fixture, from, state)
  end

  def handle_call({:control, id, key, action}, _from, state) do
    case state[id] do
      nil ->
        {:reply, {:error, :not_registered}, state}

      fixture ->
        updated = fixture |> event(action, key) |> change(key, action)
        {:reply, :ok, Map.put(state, id, updated)}
    end
  end

  defp dispatch(:verify, id, key, fixture, _from, state) do
    result =
      case fixture.resources[key] do
        nil -> {:ok, :absent}
        resources -> {:ok, :satisfied, resources}
      end

    {:reply, result, Map.put(state, id, fixture)}
  end

  defp dispatch(:execute, id, key, fixture, from, state) do
    case Map.get(fixture.modes, key, default_mode(key)) do
      :hold ->
        fixture = %{fixture | waiting: Map.update(fixture.waiting, key, [from], &[from | &1])}
        {:noreply, Map.put(state, id, fixture)}

      :refuse ->
        {:reply, {:error, "QA provider refused: token lacks permission to create this resource"},
         Map.put(state, id, fixture)}

      :paused ->
        {:reply,
         {:paused, "Register this domain in the QA provider controls, then run this step again."},
         Map.put(state, id, fixture)}

      :ready ->
        {resources, fixture} = provision(fixture, key)
        {:reply, {:ok, resources}, Map.put(state, id, fixture)}
    end
  end

  defp default_mode({"domain", _}), do: :paused
  defp default_mode(_), do: :ready

  defp change(fixture, key, "delete"),
    do: %{fixture | resources: Map.delete(fixture.resources, key)}

  defp change(fixture, key, "hold"),
    do: %{fixture | modes: Map.put(fixture.modes, key, :hold)}

  defp change(fixture, key, "refuse"),
    do: %{fixture | modes: Map.put(fixture.modes, key, :refuse)}

  defp change(fixture, key, "allow"),
    do: %{fixture | modes: Map.put(fixture.modes, key, default_mode(key))}

  defp change(fixture, key, "register") do
    {_resources, fixture} = provision(fixture, key)
    %{fixture | modes: Map.put(fixture.modes, key, :ready)}
  end

  defp change(fixture, key, "release") do
    {resources, fixture} = provision(fixture, key)
    Enum.each(Map.get(fixture.waiting, key, []), &GenServer.reply(&1, {:ok, resources}))

    %{
      fixture
      | waiting: Map.delete(fixture.waiting, key),
        modes: Map.put(fixture.modes, key, :ready)
    }
  end

  defp provision(fixture, {step, environment} = key) do
    case fixture.resources[key] do
      nil ->
        sequence = fixture.sequence + 1

        resource = %{
          kind: step,
          identifier: "qa-#{sequence}",
          location: "qa-provider/#{step}/#{environment || "project"}/#{sequence}",
          origin: "created"
        }

        resources = [resource]

        {resources,
         %{fixture | sequence: sequence, resources: Map.put(fixture.resources, key, resources)}}

      resources ->
        {resources, fixture}
    end
  end

  defp event(fixture, operation, {step, environment}) do
    event = %{
      operation: to_string(operation),
      step: step,
      environment: environment,
      at: DateTime.utc_now()
    }

    %{fixture | events: [event | fixture.events]}
  end
end
