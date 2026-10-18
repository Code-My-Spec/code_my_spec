defmodule CodeMySpec.Stories.Tools.UnassignEpicFromWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "unassign_epic_from_working_copy"

  @impl true
  def description do
    "Remove a epic on a working copy's queue."
  end

  @impl true
  def params do
    %{
      working_copy_id:
        {:required, {:meta, :string, [description: "Working copy whose queue to edit"]}},
      epic_id: {:required, {:meta, :string, [description: "Epic to remove"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, count} <-
           EpicDispatch.edit_queue(scope, :epic, params.epic_id, params.working_copy_id, :remove) do
      {:ok, "Queue updated: #{count} stories changed."}
    else
      {:error, reason} -> StoriesMapper.error(reason)
    end
  end
end
