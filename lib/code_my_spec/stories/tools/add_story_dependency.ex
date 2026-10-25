defmodule CodeMySpec.Stories.Tools.AddStoryDependency do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  @impl true
  def name, do: "add_story_dependency"

  @impl true
  def description,
    do: "Records that a story builds on another story. Refuses self-links and cycles."

  @impl true
  def params do
    %{
      story_number:
        {:required, {:meta, :integer, [description: "The story that builds on another"]}},
      builds_on: {:required, {:meta, :integer, [description: "The prerequisite story number"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, :ok} <- Stories.add_story_dependency(scope, params.story_number, params.builds_on) do
      {:ok, "Story #{params.story_number} builds on Story #{params.builds_on}."}
    end
  end
end
