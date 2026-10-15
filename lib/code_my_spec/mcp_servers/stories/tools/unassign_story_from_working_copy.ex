defmodule CodeMySpec.McpServers.Stories.Tools.UnassignStoryFromWorkingCopy do
  @moduledoc "Remove a story on a working copy's queue."
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_number, :integer, required: true, description: "Story to remove"
    field :working_copy_id, :string, required: true, description: "Working copy whose queue to edit"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, count} <-
           EpicDispatch.edit_queue(
             scope,
             :story,
             params.story_number,
             params.working_copy_id,
             :remove
           ) do
      {:reply, Response.text(Response.tool(), "Queue updated: #{count} stories changed."), frame}
    else
      {:error, reason} -> {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
