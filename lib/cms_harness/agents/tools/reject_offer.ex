defmodule CmsHarness.Agents.Tools.RejectOffer do
  @moduledoc "Decline an offer with a reason, carried directly (story 1080)."

  use CmsHarness.Agents.Tools.Direct,
    name: "reject_offer",
    nothing_to: "no offer it can decline"

  @impl true
  def description do
    """
    Decline work you were offered and should not take — already done,
    someone else's, or impossible here — with your reason. The work is held
    back from you and main is told. `offer_id` defaults to your newest open
    offer. Use `tap_out` instead when you cannot continue at all.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        offer_id: %{type: ["string", "null"], description: "Omit for your newest open offer."},
        reason: %{type: "string", description: "Why you are not taking it."}
      },
      required: ["reason"]
    }
  end
end
