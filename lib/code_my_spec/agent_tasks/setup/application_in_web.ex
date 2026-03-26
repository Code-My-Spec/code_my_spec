defmodule CodeMySpec.AgentTasks.Setup.ApplicationInWeb do
  @moduledoc """
  Setup step: Application module lives in the web namespace.
  """

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()

    case extract_app_name(dir) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `#{Path.join(dir, "mix.exs")}`"}

      app_name ->
        web_path = Path.join([dir, "lib", "#{app_name}_web", "application.ex"])

        if File.exists?(web_path),
          do: {:ok, :valid},
          else: {:ok, :invalid, "Application module not found at `#{web_path}` — still in `lib/#{app_name}/application.ex`"}
    end
  end

  def command(scope, _task) do
    dir = scope.cwd || File.cwd!()
    app_name = extract_app_name(dir) || "your_app"
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

  defp extract_app_name(dir) do
    case File.read(Path.join(dir, "mix.exs")) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end
      _ -> nil
    end
  end
end
