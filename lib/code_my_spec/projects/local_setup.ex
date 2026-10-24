defmodule CodeMySpec.Projects.LocalSetup do
  @moduledoc "Shared entry point for desktop setup tools and the setup page."
  alias CodeMySpec.Projects.Onboarding

  def run(scope, action, app \\ nil) do
    with {:ok, project} <- Onboarding.fetch(scope),
         true <- Application.get_env(:code_my_spec, :env) == :desktop,
         %{destination: :local} <- project.onboarding,
         {module, function} <- Application.get_env(:code_my_spec, :desktop_project_setup) do
      apply(module, function, [scope, project, action, app])
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "Desktop setup requires a saved local development destination. It does not provision cloud resources."}
    end
  end
end
