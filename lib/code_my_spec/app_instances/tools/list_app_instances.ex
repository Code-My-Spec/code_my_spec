defmodule CodeMySpec.AppInstances.Tools.ListAppInstances do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.{AppInstances, Tools}
  alias CodeMySpec.AppInstances.Tools.Presentation

  @impl true
  def name, do: "list_app_instances"

  @impl true
  def description do
    "List all recorded app instances in the current project, including deployments without " <>
      "working copies and unassigned instances. Reports bindings, last recorded status, revisions " <>
      "and preview URLs; timestamps indicate when status was checked, not live health. Does not " <>
      "create instances or contact devices. Use get_app_instance for one instance. Lifecycle " <>
      "tools control the caller's working copy, or Main's explicitly connected working copies by instance ID; provisioned deployments use provisioning."
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      {:ok, Enum.map(AppInstances.list(scope), &Presentation.row/1)}
    end
  end
end
