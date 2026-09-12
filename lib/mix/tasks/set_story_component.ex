defmodule Mix.Tasks.SetStoryComponent do
  use Boundary, classify_to: CodeMySpec

  @moduledoc """
  Links a story to an architecture component by module name.

  ## Usage

      mix set_story_component <story_id> <module_name>

  Looks up the component by module name within the current project
  and links it to the specified story.

  Requires a `.code_my_spec/config.yml` in the current directory.
  """

  use Mix.Task

  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories

  @shortdoc "Link a story to an architecture component by module name"

  def run([story_id, module_name]) do
    Mix.Task.run("app.start")

    case Projects.scope_from_local_config(File.cwd!()) do
      {:ok, scope} ->
        link_story(scope, story_id, module_name)

      {:error, reason} ->
        Mix.shell().error("Failed to load project scope: #{inspect(reason)}")
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix set_story_component <story_id> <module_name>")
  end

  defp link_story(scope, story_id, module_name) do
    with story when not is_nil(story) <- Stories.get_story(scope, story_id),
         component when not is_nil(component) <-
           Components.get_component_by_module_name(scope, module_name),
         {:ok, updated} <- Stories.set_story_component(scope, story, component.id) do
      Mix.shell().info(
        "Linked story \"#{updated.title}\" to #{module_name} (#{component.id})"
      )
    else
      nil ->
        Mix.shell().error(
          ~s(Not found. Verify story ID "#{story_id}" and module name "#{module_name}" exist.)
        )

      {:error, reason} ->
        Mix.shell().error("Failed to link: #{inspect(reason)}")
    end
  end
end
