defmodule CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories do
  @moduledoc """
  MCP tool for analyzing user stories to extract domain patterns and suggest bounded contexts.

  Particularly useful for greenfield projects where no components exist yet.
  Returns a hybrid response with markdown summary and JSON data.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Architecture.StoryAnalyzer
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :app_name, :string
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame) do
      stories = Stories.list_project_stories(scope)

      if stories == [] do
        {:reply, ArchitectureMapper.error("No stories found. Import stories first using the stories tools."), frame}
      else
        opts = [app_name: params[:app_name] || derive_app_name(scope)]
        analysis = StoryAnalyzer.analyze(stories, opts)
        {:reply, ArchitectureMapper.story_analysis_response(analysis), frame}
      end
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp derive_app_name(scope) do
    scope.project.name
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> Macro.camelize()
  end
end
