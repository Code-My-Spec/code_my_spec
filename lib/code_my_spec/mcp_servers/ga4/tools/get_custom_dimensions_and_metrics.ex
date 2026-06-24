defmodule CodeMySpec.McpServers.Ga4.Tools.GetCustomDimensionsAndMetrics do
  @moduledoc "Return the property's custom dimensions and metrics."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string,
      required: true,
      doc: "Property ID — a number, or a string like \"properties/123456789\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.get_custom_dimensions_and_metrics(token, params.property_id) do
      summary =
        "#{length(data.custom_dimensions)} custom dimensions, #{length(data.custom_metrics)} custom metrics."

      {:reply, GoogleTools.ok(summary, data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
