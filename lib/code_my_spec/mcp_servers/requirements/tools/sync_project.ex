defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProject do
  @moduledoc """
  Sync project components and requirements.

  Triggers an incremental sync that detects changed components and
  recalculates their requirements. Run this after init, after making
  changes, or when the requirements graph seems stale.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.ProjectSync.Sync

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      case Sync.sync_all(scope) do
        {:ok, result} ->
          components = length(Map.get(result, :all_components, []))
          changed = length(Map.get(result, :changed_ids, []))

          text = """
          # Sync Complete

          - Components: #{components}
          - Changed: #{changed}

          Call `get_next_requirement` to find your next task.
          """

          response =
            Response.tool()
            |> Response.text(text)
            |> Map.put(:structured_content, %{
              status: :ok,
              components: components,
              changed: changed
            })

          {:reply, response, frame}

        {:error, reason} ->
          {:reply, Response.tool() |> Response.error("Sync failed: #{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end
end
