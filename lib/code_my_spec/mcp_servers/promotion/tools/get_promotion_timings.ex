defmodule CodeMySpec.McpServers.Promotion.Tools.GetPromotionTimings do
  @moduledoc "Read promotion timing figures for a project's recent window."
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.PromotionQueue.Timings

  schema do
    field :window, :string, description: "24h or 7d; defaults to 24h"
  end

  @impl true
  def execute(params, frame) do
    window = Map.get(params, :window) || "24h"

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         true <- window in ["24h", "7d"] do
      {:reply,
       Response.tool()
       |> Response.text(Jason.encode!(Timings.summary(scope.active_project_id, window))), frame}
    else
      _ -> {:reply, Response.tool() |> Response.error("Project or window is unavailable"), frame}
    end
  end
end
