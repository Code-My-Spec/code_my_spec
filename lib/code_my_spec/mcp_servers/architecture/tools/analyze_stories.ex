defmodule CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories do
  @moduledoc """
  MCP tool for analyzing user stories to extract domain patterns and suggest bounded contexts.

  Particularly useful for greenfield projects where no components exist yet.
  Returns a hybrid response with markdown summary and JSON data.
  """

  use Hermes.Server.Component, type: :tool
  require Logger

  alias CodeMySpec.Architecture.StoryAnalyzer
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :app_name, :string
  end

  @impl true
  def execute(params, frame) do
    Logger.info("[AnalyzeStories] Starting execution with params: #{inspect(params)}")
    start = System.monotonic_time(:millisecond)

    with {:ok, scope} <- Validators.validate_project_scope(frame) do
      Logger.info("[AnalyzeStories] Scope validated in #{System.monotonic_time(:millisecond) - start}ms")

      stories = Stories.list_project_stories(scope)
      Logger.info("[AnalyzeStories] Fetched #{length(stories)} stories in #{System.monotonic_time(:millisecond) - start}ms")

      if stories == [] do
        {:reply, ArchitectureMapper.error("No stories found. Import stories first using the stories tools."), frame}
      else
        opts = [app_name: params[:app_name] || derive_app_name(scope)]
        analysis = StoryAnalyzer.analyze(stories, opts)
        Logger.info("[AnalyzeStories] Analysis complete in #{System.monotonic_time(:millisecond) - start}ms")

        response = ArchitectureMapper.story_analysis_response(analysis)
        Logger.info("[AnalyzeStories] Response built in #{System.monotonic_time(:millisecond) - start}ms")

        {:reply, response, frame}
      end
    else
      {:error, reason} ->
        Logger.error("[AnalyzeStories] Error: #{inspect(reason)}")
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp derive_app_name(scope) do
    scope.project.name
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> Macro.camelize()
  end
end
