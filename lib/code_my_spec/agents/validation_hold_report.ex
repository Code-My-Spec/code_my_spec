defmodule CodeMySpec.Agents.ValidationHoldReport do
  @moduledoc "Push durable validation state and terminal handoffs to main."
  require Logger
  alias CodeMySpec.Agents

  @event [:code_my_spec, :analysis, :validation_hold]

  def attach do
    :telemetry.attach({__MODULE__, :deliver}, @event, &__MODULE__.handle_event/4, nil)
  end

  def handle_event(@event, _measurements, %{scope: scope, hold: hold}, _config) do
    Agents.notify_main(scope, :own_reply, message(hold),
      offer: {:instruction, {"validation_hold", hold.id}}
    )
  rescue
    error -> Logger.error("Validation hold notification failed: #{Exception.message(error)}")
  end

  def message(hold) do
    "Validation hold #{hold.id}: #{hold.status}. Owner: #{hold.owner_agent_id}. " <>
      "Reason: #{hold.reason}. Affected copies: #{Enum.join(hold.affected_copy_ids, ", ")}. " <>
      "Authorized copy: #{hold.authorized_copy_id || "none"}; source: #{hold.source || "none"}; " <>
      "args: #{inspect(hold.args)}; run: #{hold.run_id || "none"}. " <>
      "Next recipient: #{hold.next_agent_id}. Outcome: #{inspect(hold.outcome)}. " <>
      instruction(hold.status)
  end

  defp instruction(:awaiting_handoff),
    do:
      "Execution ownership is released. Record the next authorization or release the hold; no run starts automatically. Failure is not a validation pass."

  defp instruction(:unknown),
    do:
      "Execution remains unknown. Do not release or start another run without confirmed terminal evidence."

  defp instruction(_status), do: "Read and manage this record with validation_hold."
end
