defmodule CodeMySpec.Stories.Tools.RemoveStoryDependency do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  @impl true
  def name, do: "remove_story_dependency"

  @impl true
  def description, do: "Removes a story's builds-on link to another story."

  @impl true
  def params, do: CodeMySpec.Stories.Tools.AddStoryDependency.params()

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, :ok} <-
           Stories.remove_story_dependency(scope, params.story_number, params.builds_on) do
      {:ok, "Removed Story #{params.story_number}'s builds-on link to Story #{params.builds_on}."}
    end
  end
end
