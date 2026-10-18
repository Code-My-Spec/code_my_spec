defmodule CodeMySpec.Stories.Tools.UnassignStoryFromWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "unassign_story_from_working_copy"

  @impl true
  def description do
    "Remove a story on a working copy's queue."
  end

  @impl true
  def params do
    %{
      working_copy_id:
        {:required, {:meta, :string, [description: "Working copy whose queue to edit"]}},
      story_number: {:required, {:meta, :integer, [description: "Story to remove"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, count} <-
           EpicDispatch.edit_queue(
             scope,
             :story,
             params.story_number,
             params.working_copy_id,
             :remove
           ) do
      {:ok, "Queue updated: #{count} stories changed."}
    else
      {:error, reason} -> StoriesMapper.error(reason)
    end
  end
end
