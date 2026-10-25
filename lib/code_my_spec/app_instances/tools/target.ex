defmodule CodeMySpec.AppInstances.Tools.Target do
  @moduledoc false

  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.Agents
  alias CodeMySpec.Environments
  alias CodeMySpec.AppInstances
  alias CodeMySpec.WorkingCopies

  @doc "Resolve the caller's working copy to its default app instance."
  def own_default(scope, context, requested_id \\ nil)

  def own_default(scope, _context, requested_id) when is_binary(requested_id) do
    copy_id = scope.active_working_copy_id

    case fetch_instance(scope, requested_id) do
      {:ok, %{working_copy_id: ^copy_id} = instance} when is_binary(copy_id) -> {:ok, instance}
      _ -> {:error, :instance_not_owned}
    end
  end

  def own_default(scope, _context, nil) when is_binary(scope.active_working_copy_id) do
    copy_id = scope.active_working_copy_id

    with {:ok, copy} <- WorkingCopies.fetch(copy_id) do
      AppInstances.ensure_default(scope, copy)
    end
  end

  def own_default(_scope, _context, _requested_id), do: {:error, :missing_active_working_copy}

  @doc "Resolve an explicit harness instance through ownership or Main's existing attachment."
  def lifecycle(scope, context, requested_id) when is_binary(requested_id) do
    with {:ok, instance} <- fetch_instance(scope, requested_id),
         :ok <- harness_instance(scope, instance),
         :ok <- authorized_source(scope, context, instance) do
      {:ok, instance}
    end
  end

  def lifecycle(scope, context, nil) do
    with {:ok, instance} <- own_default(scope, context),
         :ok <- harness_instance(scope, instance) do
      {:ok, instance}
    end
  end

  defp harness_instance(scope, instance) do
    environment =
      if instance.environment_id, do: Environments.get_by_id(scope, instance.environment_id)

    cond do
      match?(%{management: :provisioned}, environment) or is_binary(instance.deployment_image) ->
        {:error, :provisioned_instance}

      not is_binary(instance.working_copy_id) or not is_binary(instance.source_root) or
          instance.source_root == "" ->
        {:error, :instance_without_source}

      true ->
        :ok
    end
  end

  defp authorized_source(scope, _context, %{working_copy_id: copy_id})
       when is_binary(copy_id) and copy_id == scope.active_working_copy_id,
       do: :ok

  defp authorized_source(scope, context, instance) do
    agent_id = context[:agent_id] || Agents.terminal_agent_id(scope, context[:session_id])

    case AgentAttachments.list(scope, agent_id) do
      attachments when is_list(attachments) ->
        if Enum.any?(attachments, &(&1.working_copy_id == instance.working_copy_id)),
          do: :ok,
          else: {:error, :instance_not_owned}

      _ ->
        {:error, :instance_not_owned}
    end
  end

  def error(:provisioned_instance),
    do:
      "This instance is provisioned; use the environment's provisioning workflow, not harness lifecycle tools."

  def error(:instance_without_source),
    do:
      "This instance has no harness source checkout. Harness lifecycle tools require a working copy and source root."

  def error(:not_found),
    do: "App instance not found in the active project. Use list_app_instances."

  def error(:instance_not_owned),
    do:
      "This instance is outside the caller's working copy. Main must connect to its working copy first; other agents can control only their own copy."

  def error(:missing_active_working_copy),
    do:
      "This call has no working copy of its own. Main can select an explicit instance_id after connecting to its working copy."

  def error(reason), do: "Cannot resolve app instance: #{inspect(reason)}"

  defp fetch_instance(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case AppInstances.get(scope, id) do
          nil -> {:error, :not_found}
          instance -> {:ok, instance}
        end

      :error ->
        {:error, :not_found}
    end
  end
end
