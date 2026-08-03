defmodule CodeMySpec.AgentTasks.Setup.ApplicationInWeb do
  @moduledoc """
  Setup step: Application module lives in the web namespace.

  The file lives at `lib/{app}_web/application.ex` — `FileSync` already
  syncs `lib/` and classifies it as `:implementation`, so we check
  whether the path is registered as a synced File.
  """

  import Ecto.Query

  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo

  def check(%Context{} = ctx) do
    case Context.app_name(ctx) do
      nil ->
        {:invalid, "Could not determine app name from `mix.exs`"}

      app ->
        web_path = Path.join(["lib", "#{app}_web", "application.ex"])

        if web_application_synced?(ctx, web_path),
          do: :valid,
          else:
            {:invalid,
             "Application module not found at `#{web_path}` — still in `lib/#{app}/application.ex`"}
    end
  end

  # `:implementation` files aren't preloaded into Setup.Context (would
  # explode the result set). One targeted, project-scoped query — still
  # cheaper than the filesystem stat the old check did, and correct against
  # the synced state the rest of the graph is computed against.
  defp web_application_synced?(%Context{project_id: nil}, _path), do: false

  defp web_application_synced?(%Context{project_id: project_id}, path) do
    FileRecord
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> Repo.exists?()
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(scope, _task) do
    app_name = Helpers.app_name(scope)
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
