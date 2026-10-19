defmodule CodeMySpecSpex.Story1053.Criterion2026Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question across its working
  copies.
  Criterion 2026 — A new question or tap-out notifies the main agent right
  away. Title only; no scenario was recorded.

  Rule: a persisted question immediately reconsiders eligible main-agent work
  through normal turn admission, without a generic push message.

  "Right away" means right after the question commits, not at the main
  agent's next check-in or recovery-timer tick (criterion 2027, and the
  story's own notes: "reconsider the existing main agent through Agents.Work
  without waiting for the recovery timer"). The scenario never calls
  `CheckIn` — proving that is the point: a runnable main agent reaches the
  provider on its own, before anything would have polled for it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A runnable main agent reaches the provider right after a question commits",
    criterion: 2026 do
    scenario "a coding agent raises a new question and a continuous, idle main is given a turn" do
      given_ "a continuous, idle main agent is running", context do
        context = given_a_staffed_checkout(context, "spex_2026")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(main.id)

        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coding_frame: coding_frame
         })}
      end

      when_ "coding raises a new question, and nobody ever checks in", context do
        asked =
          ToolLibrary.run(
            "ask_question",
            %{
              questions: [
                %{
                  question: "Which export format should coding use?",
                  options: [%{label: "CSV"}, %{label: "JSON"}]
                }
              ]
            },
            Map.put(
              context.coding_frame.assigns,
              :scope,
              context.coding_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, asked), response_text(asked)
        {:ok, context}
      end

      then_ "the main agent reaches the provider right away, without a check-in", context do
        # The reconsideration is dispatched off the asking process: wait for
        # main's turn to reach the provider before asking whether it is busy.
        HeldProvider.await_request()

        assert {:ok, %{busy?: true}} = Machine.status(context.main_id),
               """
               The main agent was not given a turn right after the question
               committed. Nothing in this scenario ever calls CheckIn, so a
               turn here can only mean the question's own creation reconsidered
               eligible main-agent work on its own.
               """

        {:ok, context}
      end
    end
  end
end
