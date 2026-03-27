defmodule CodeMySpec.AgentTasks.Setup.ApplicationInWeb do
  @moduledoc """
  Setup step: Application module lives in the web namespace.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment

    case Helpers.extract_app_name(env) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `mix.exs`"}

      app_name ->
        web_path = Path.join(["lib", "#{app_name}_web", "application.ex"])

        if Environments.file_exists?(env, web_path),
          do: {:ok, :valid},
          else: {:ok, :invalid, "Application module not found at `#{web_path}` — still in `lib/#{app_name}/application.ex`"}
    end
  end

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    module_name = Macro.camelize(app_name)

    {:ok, """
    # Move Application Module to Web Namespace

    The `#{module_name}.Application` module supervises both `#{module_name}.Repo` and
    `#{module_name}Web.Endpoint`, creating a boundary violation. Move it:

    1. `mv lib/#{app_name}/application.ex lib/#{app_name}_web/application.ex`
    2. Rename module to `#{module_name}Web.Application`
    3. Update `mix.exs` — `mod: {#{module_name}Web.Application, []}`
    """}
  end
end
