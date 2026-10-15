defmodule CodeMySpec.Agents.Tools.RejectOffer do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Tools

  @impl true
  def name, do: "reject_offer"

  @impl true
  def description do
    """
    Decline an offer with a reason (story 1080, criterion 1738).

    For work you were offered and should not take — already satisfied, someone
    else's, impossible here. The offer settles as declined, the work is held
    back from you, and main is told why. `tap_out` stays for "I cannot continue"
    and for leaving the loop.
    """
  end

  @impl true
  def params do
    %{
      offer_id:
        {:meta, :string, [description: "The offer to decline; omit for your newest open offer."]},
      reason: {:required, {:meta, :string, [description: "Why you are not taking it."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, agent_id} <- agent_id(context),
         {:ok, offer} <-
           Agents.reject_offer(context.scope, agent_id, params[:offer_id], params[:reason]) do
      {:ok,
       "Declined offer #{offer.id} (#{offer.subject_type} #{offer.subject_key}). " <>
         "It is held back from you, and main has your reason. End your turn or take other work."}
    else
      {:error, :not_found} ->
        {:error,
         "No open offer #{params[:offer_id] || ""} to decline. It may already be settled."}

      {:error, reason} ->
        Tools.error(reason)
    end
  end

  defp agent_id(%{agent_id: id}) when is_binary(id), do: {:ok, id}

  defp agent_id(_context),
    do:
      {:error, "`reject_offer` is for agents the harness offers work to; this session has none."}
end
