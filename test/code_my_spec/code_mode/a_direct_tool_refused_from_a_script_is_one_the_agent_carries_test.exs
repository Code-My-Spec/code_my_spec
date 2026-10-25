defmodule CodeMySpec.CodeMode.ADirectToolRefusedFromAScriptIsOneTheAgentCarriesTest do
  @moduledoc """
  Every agent's engine carries the direct tools whatever its role, so a QA
  agent calling `start_task` from a script is told to call it directly. It was
  told the tool belonged to another role, because the refusal read only the
  role's grant, and it stopped short of claiming work it could claim.
  """
  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    {:ok, qa} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        status: :running,
        working_copy: "/tmp/direct-from-script-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    %{frame: %Frame{assigns: %{current_scope: ctx.scope, agent_id: qa.id}}}
  end

  for tool <- ~w(get_next_requirement start_task evaluate_task) do
    test "#{tool} from a script is called directly instead, not another role's", ctx do
      {:reply, response, _frame} =
        RunScript.execute(%{script: "return #{unquote(tool)}({})"}, ctx.frame)

      text = response_text(response)
      assert text =~ "Call it directly as a tool"
      refute text =~ "belongs to another role"
    end
  end
end
