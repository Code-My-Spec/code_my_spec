defmodule CodeMySpecSpex.Story1024.Criterion2894Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2894 — A turn that fails still shows what it did first.

  Rule: An agent's work appears as it happens, not only when the turn ends.

  The failure path that matters more than its happy path, and the one the
  obvious implementation gets wrong.

  Buffering a turn and writing it when it completes passes "I watch the work
  arrive" on any turn that succeeds, and loses everything on the turns you most
  wanted to watch. Streaming exists so you can see an agent going wrong early;
  if the record of what it did evaporates the moment it fails, you get the
  worst of both — no live view of the mistake, and no history of it either.

  So a step that happened is a step that stays, whatever the turn does
  afterwards.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "What already happened is not undone by what happens next" do
    scenario "A turn that fails still shows what it did first" do
      given_ "an agent part-way through a turn", context do
        copy = CodeMySpec.TempFile.dir("spex_2894")
        File.mkdir_p!(copy)

        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        Fixtures.agent_reports_step(context.scope, agent, %{
          "type" => "tool_use",
          "name" => "write",
          "input" => %{"file_path" => "lib/half_done.ex"}
        })

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "the turn then fails", context do
        Fixtures.agent_reports_failure(
          context.scope,
          context.agent,
          "codex exec failed with status 1"
        )

        {:ok, context}
      end

      then_ "the steps it completed before failing are there", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)
        messages = Fixtures.conversation_messages(context.scope, conversation)

        assert Enum.any?(messages, &(Fixtures.message_text(&1) =~ "half_done")),
               "the work the agent did before the turn failed is gone. That is the " <>
                 "buffered implementation: hold the turn, write it on success, lose " <>
                 "it on failure — which loses exactly the turns worth watching."

        {:ok, Map.put(context, :messages, messages)}
      end

      then_ "and the failure is shown rather than the work disappearing with it",
            context do
        assert Enum.any?(context.messages, &(Fixtures.message_text(&1) =~ "failed")),
               "the turn failed and the conversation does not say so, which leaves " <>
                 "an operator watching a transcript that simply stops"

        {:ok, context}
      end
    end
  end
end
