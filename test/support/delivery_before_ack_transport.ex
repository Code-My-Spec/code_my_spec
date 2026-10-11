defmodule CodeMySpecTest.DeliveryBeforeAckTransport do
  @moduledoc "A transport boundary that delivers before its transport acknowledgement returns."

  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  def dispatch_message(_copy_id, agent, ref, _text, _timeout) do
    scope = %Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id,
      active_working_copy_id: agent.working_copy_id
    }

    {:ok, _} = Agents.Mailbox.consume(scope, agent.id, ref, "test-engine")

    {:ok, :started}
  end
end
