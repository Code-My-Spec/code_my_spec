defmodule CodeMySpec.Provisioning.Tools.RotateRegistryCredential do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Tools.Starter
  alias CodeMySpec.Resources

  @impl true
  def name, do: "rotate_registry_credential"

  @impl true
  def description do
    "Replace this project's registry credential on the environment's linked server. The run verifies that the old credential is rejected and the new one can log in and pull. Returns no credential. It runs under the project's provisioning lock and reports the result when finished."
  end

  @impl true
  def params do
    %{environment: {:required, {:meta, :string, [description: "Linked environment, e.g. prod."]}}}
  end

  @impl true
  def call(%{environment: environment}, context)
      when is_binary(environment) and environment != "" do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      project_scope = Resources.project_scope(scope, project)
      starter = Starter.new(scope, context, "registry credential rotation")

      project_scope
      |> start_rotation(project.id, environment, starter)
      |> reply(context)
    else
      _ -> {:error, "Could not start registry credential rotation."}
    end
  end

  def call(_, _), do: {:error, "An environment is required."}

  defp start_rotation(scope, project_id, environment, starter) do
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true ->
        spawn_rotation(scope, project_id, environment, starter)

      _ ->
        RunLock.with_lock(project_id, fn ->
          Steps.rotate_registry_credential(scope, environment)
        end)
    end
  end

  defp spawn_rotation(scope, project_id, environment, starter) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(
          project_id,
          fn ->
            send(parent, {ref, :locked})
            Steps.rotate_registry_credential(scope, environment)
          end,
          Starter.lock_holder(starter)
        )
        |> case do
          {:error, {:already_running, _}} = refused -> send(parent, {ref, refused})
          outcome -> Starter.tell(starter, outcome_message(outcome))
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, {:error, {:already_running, _}} = refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp reply({:ok, :started}, context),
    do: {:ok, "Registry credential rotation started; #{Starter.then_what(context[:agent_id])}"}

  defp reply(:ok, _context), do: {:ok, "Registry credential rotation verified."}

  defp reply({:error, {:already_running, _}}, _context),
    do: {:error, "A provisioning run is already in progress for this project."}

  defp reply({:error, reason}, _context), do: {:error, failure_message(reason)}

  defp outcome_message(:ok), do: "Registry credential rotation verified."
  defp outcome_message({:error, reason}), do: failure_message(reason)

  defp failure_message(:registry_not_provisioned),
    do: "Registry credential rotation failed: linked registry server is unavailable."

  defp failure_message(:old_credential_still_accepted),
    do: "Registry credential rotation failed: old credential still authenticates."

  defp failure_message(:new_credential_rejected),
    do: "Registry credential rotation failed: new credential was rejected."

  defp failure_message(:docker_login_failed),
    do: "Registry credential rotation failed: Docker login verification."

  defp failure_message(:docker_pull_failed),
    do: "Registry credential rotation failed: Docker pull verification."

  defp failure_message(_), do: "Registry credential rotation failed; check registry provisioning."
end
