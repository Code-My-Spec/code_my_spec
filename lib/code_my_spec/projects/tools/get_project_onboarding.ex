defmodule CodeMySpec.Projects.Tools.GetProjectOnboarding do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Projects.{Onboarding, Tools}

  @impl true
  def name, do: "get_project_onboarding"
  @impl true
  def description do
    "Read the connected project's saved definition, starting point, development destination, " <>
      "selected sources and accessible device IDs. No working copy is required. " <>
      "A selected source is not an inspected or provisioned environment."
  end

  @impl true
  def params, do: %{}
  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.text()
  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- Onboarding.fetch(scope) do
      {:ok, Tools.snapshot(project, scope)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end
end
