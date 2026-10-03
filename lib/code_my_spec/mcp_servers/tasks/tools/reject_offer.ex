defmodule CodeMySpec.McpServers.Tasks.Tools.RejectOffer do
  @moduledoc """
  Decline an offer with a reason (story 1080, criterion 1738).

  For work you were offered and should not take — already satisfied, someone
  else's, impossible here. The offer settles as declined, the work is held back
  from you, and main is told why. `tap_out` stays for "I cannot continue" and
  for leaving the loop.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators

  schema do
    field :offer_id, :string, doc: "The offer to decline; omit for your newest open offer."
    field :reason, :string, required: true, doc: "Why you are not taking it."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, agent_id} <- agent_id(frame),
         {:ok, offer} <- Agents.reject_offer(scope, agent_id, params[:offer_id], params[:reason]) do
      {:reply,
       Response.tool()
       |> Response.text(
         "Declined offer #{offer.id} (#{offer.subject_type} #{offer.subject_key}). " <>
           "It is held back from you, and main has your reason. End your turn or take other work."
       ), frame}
    else
      {:error, :not_found} ->
        {:reply,
         Response.tool()
         |> Response.error(
           "No open offer #{params[:offer_id] || ""} to decline. It may already be settled."
         ), frame}

      {:error, reason} when is_binary(reason) ->
        {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end

  defp agent_id(%{assigns: %{agent_id: id}}) when is_binary(id), do: {:ok, id}

  defp agent_id(_frame),
    do:
      {:error, "`reject_offer` is for agents the harness offers work to; this session has none."}
end
