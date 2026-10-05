defmodule CodeMySpecTest.DeliveryBeforeAckTransport do
  @moduledoc "A transport boundary that delivers before its queued acknowledgement returns."

  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  def dispatch_message(_copy_id, agent, ref, _text, _timeout) do
    scope = %Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id,
      active_working_copy_id: agent.working_copy_id
    }

    :ok =
      Agents.record_turn_event(scope, agent.id, %{
        "kind" => "message_delivered",
        "ref" => ref
      })

    {:ok, :queued}
  end
end
