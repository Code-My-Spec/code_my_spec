defmodule CodeMySpecSpex.Story1016.Criterion1773Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1773 — A tool call that names an agent but no working copy acts in
  that agent's own working copy, files included; a call that names a working
  copy acts there, and a mismatch with the calling agent's copy is logged, not
  refused.

  ed28189c: a call naming only `X-Agent-Id` over the hosted `/mcp/harness` had
  a project and no working copy, so file tools refused it with
  `:no_environment`. John: which copy is part of who is calling.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.StoryBoundHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import ExUnit.CaptureLog

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecWeb.Plugs.AgentScope

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The hosted pipeline's last step, then a tool that writes a file through the
  # frame's working copy, as `/mcp/harness` runs them: `ProjectScopeOverride`
  # has set the project and, when a harness was named, its copy; `AgentScope`
  # resolves `X-Agent-Id`; Anubis hands the conn's assigns to the tool.
  defp hosted_call(scope, agent) do
    conn =
      :post
      |> Phoenix.ConnTest.build_conn("/mcp/harness", "")
      |> Plug.Conn.assign(:current_scope, scope)
      |> Plug.Conn.put_req_header("x-agent-id", agent.id)
      |> AgentScope.call([])

    reply =
      ToolLibrary.run(
        "regenerate_proposal",
        %{confirm: true},
        Map.put(conn.assigns, :scope, conn.assigns[:current_scope])
      )

    {response_text(reply), conn.assigns.current_scope}
  end

  spex "A call naming only an agent acts in that agent's copy", criterion: 1773 do
    scenario "the coding agent calls with X-Agent-Id and no harness" do
      given_ "a team on its story, on this working copy", context do
        {:ok, team_on_a_story(context)}
      end

      when_ "the coding agent writes the proposal, naming itself and no copy", context do
        no_copy = %{context.scope | active_working_copy_id: nil}
        {text, scope} = hosted_call(no_copy, context.coding)
        {:ok, Map.merge(context, %{text: text, acted_in: scope})}
      end

      then_ "the call acts in the agent's own copy", context do
        assert context.acted_in.active_working_copy_id == context.coding.working_copy_id
        {:ok, context}
      end

      then_ "and its files are reachable, not refused for want of an environment", context do
        refute context.text =~ "no_environment", context.text
        {:ok, context}
      end
    end
  end

  spex "A named copy stands over the calling agent's", criterion: 1773 do
    scenario "the call names a copy that is not the agent's" do
      given_ "a team on its story, on this working copy", context do
        {:ok, team_on_a_story(context)}
      end

      when_ "the coding agent calls naming a different copy", context do
        named = %{context.scope | active_working_copy_id: Ecto.UUID.generate()}

        {{_text, scope}, log} =
          with_log([level: :warning], fn -> hosted_call(named, context.coding) end)

        {:ok,
         Map.merge(context, %{acted_in: scope, log: log, named: named.active_working_copy_id})}
      end

      then_ "the named copy is the one acted on, not the agent's", context do
        assert context.acted_in.active_working_copy_id == context.named
        {:ok, context}
      end

      then_ "and the mismatch is logged rather than refused", context do
        assert context.log =~ "naming working copy #{context.named}", context.log
        {:ok, context}
      end
    end
  end
end
