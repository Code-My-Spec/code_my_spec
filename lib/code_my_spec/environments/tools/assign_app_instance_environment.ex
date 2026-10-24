defmodule CodeMySpec.Environments.Tools.AssignAppInstanceEnvironment do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.{AppInstances, Environments, Tools}

  @impl true
  def name, do: "assign_app_instance_environment"

  @impl true
  def description do
    """
    Assign an existing app instance to a durable environment in this project.
    Both IDs must belong to the current project. This only changes the binding;
    it does not start, stop, deploy or move the app, checkout, device or agents.
    Use list_environments and list_working_copies to inspect the available IDs.
    """
  end

  @impl true
  def params do
    %{
      instance_id:
        {:required, {:meta, :string, [description: "App instance UUID in this project."]}},
      environment_id:
        {:required, {:meta, :string, [description: "Durable environment UUID in this project."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(%{instance_id: instance_id, environment_id: environment_id}, context) do
    with {:ok, scope} <- Tools.project_scope(context),
         environment when not is_nil(environment) <- Environments.get_by_id(scope, environment_id),
         instance when not is_nil(instance) <- AppInstances.get(scope, instance_id),
         {:ok, updated} <- AppInstances.update(scope, instance, %{environment_id: environment.id}) do
      {:ok, %{"instance_id" => updated.id, "environment_id" => updated.environment_id}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end
end
