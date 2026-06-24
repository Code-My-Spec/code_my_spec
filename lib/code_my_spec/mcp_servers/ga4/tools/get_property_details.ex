defmodule CodeMySpec.McpServers.Ga4.Tools.GetPropertyDetails do
  @moduledoc "Return details about a Google Analytics property."
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
         {:ok, data} <- Ga4.get_property_details(token, params.property_id) do
      {:reply, GoogleTools.ok("Property details.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
