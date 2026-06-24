defmodule CodeMySpec.McpServers.Ga4.Tools.ListPropertyAnnotations do
  @moduledoc """
  Return reporting data annotations for a property. Annotations are notes on
  GA4 for specific dates or periods (releases, campaigns, traffic events).
  """
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
         {:ok, data} <- Ga4.list_property_annotations(token, params.property_id) do
      {:reply, GoogleTools.ok("Found #{length(data)} annotations.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
