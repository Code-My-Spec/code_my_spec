defmodule CodeMySpecSpex.Story1059.Criterion3333Spex do
  @moduledoc """
  A failed digest records its unavailable source without manufacturing a turn.
  Fault injection is project-scoped; the real check-in and issue surfaces run.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Failed recovery evidence is not an empty digest or an admission override",
    criterion: 1301 do
    scenario "An unavailable analyzer ledger is recorded while main stays autonomous-off" do
      given_ "the main agent is idle with continuous off and a digest source unavailable",
             context do
        context = given_a_staffed_checkout(context, "spex_3333")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(main.id)
        {:reply, conversation, _} = ReadAgentConversation.execute(%{agent_id: main.id}, frame)
        refute conversation.isError, response_text(conversation)
        :ok = Fixtures.break_digest_source(context.scope)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           frame: frame,
           conversation_before: response_text(conversation),
           running_ids: Machine.running()
         })}
      end

      when_ "recovery tries to assemble the digest", context do
        {:reply, _response, _} = CheckIn.execute(%{}, context.frame)
        {:ok, context}
      end

      then_ "the recorded failure names the unavailable source rather than claiming all is well",
            context do
        issues =
          ToolLibrary.run(
            "list_issues",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, issues), response_text(issues)
        assert response_text(issues) =~ ~r/check.in.*could not|digest.*fail/i
        [_, issue_id] = Regex.run(~r/ID: ([a-f0-9-]+)/, response_text(issues))

        issue =
          ToolLibrary.run(
            "get_issue",
            %{issue_id: issue_id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, issue), response_text(issue)
        assert response_text(issue) =~ "analyzer ledger"
        assert response_text(issue) =~ ~r/did not answer|unavailable|failed/i
        {:ok, context}
      end

      then_ "the failure has not started a turn or written a control message", context do
        assert {:ok, %{busy?: false}} = Machine.status(context.main_id)
        assert Machine.running() == context.running_ids
        assert HeldProvider.seen() == []

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.main_id}, context.frame)

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end
