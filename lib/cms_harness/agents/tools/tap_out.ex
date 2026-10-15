defmodule CmsHarness.Agents.Tools.TapOut do
  @moduledoc """
  The way out of the loop, carried directly.

  `CodeMode.Catalog` excludes it with "it ends your turn, which is yours to do
  and not a script's" — an argument about scripts, and the engine did not carry
  it either, so the exit was reachable by no route at all.

  `Agents.Menu.tap_out_offer/1` prints it on every refusal an agent gets
  inside the loop: "if continuing is not worth the tokens, `tap_out` asks to
  leave it". That offer was made to agents that could not take it.

  Worth being exact about what this buys, because the moduledoc on the offer is:
  `tap_out` publishes a permission request and waits on a human, so it is not an
  escape an agent can take alone. The one that fires unattended is R8's stuck
  detection at five identical blocks.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "tap_out",
    nothing_to: "no loop it can leave"

  @impl true
  def description do
    """
    Ask a person to disposition blocked work. Supply task_id to block that task;
    approval cancels the attempt, rejection permits deliberate resumption.
    Omit task_id or pass null to request that continuous work be turned off
    upon approval. Unrelated work may continue while a task decision is pending.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        task_id: %{
          type: ["string", "null"],
          description: "Task to block; null asks to stop continuous work."
        },
        reason: %{type: "string", description: "Why this work should stop."}
      },
      required: []
    }
  end
end
