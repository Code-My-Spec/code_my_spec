defmodule CodeMySpecSpex.Story1054.Criterion1604Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 1604 — The main agent is told when a teammate stalls, dies or is
  reaped, even with its own question open.

  John's wake rules for main: a teammate going down is one of the events that
  reaches main even while it waits on an answer of its own. Its own pending
  question holds only the generic turn-end nudge.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy_socket: 4, agent_down: 3]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "The main agent is told when a teammate stalls, dies or is reaped, even with its own question open",
    criterion: 1604 do
    scenario "A coder's process dies while main waits on the user" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a continuous main agent on the main checkout, and a coder", context do
        {:ok, _} =
          CodeMySpec.WorkingCopies.designate_main(
            context.scope,
            context.scope.active_working_copy_id
          )

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coder = Fixtures.running_agent(context.scope, role: "coding")
        {:ok, Map.merge(context, %{main: main, coder: coder})}
      end

      given_ "main has asked the user a question that is still open", context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.main.id}}

        asked =
          ToolLibrary.run(
            "ask_user_question",
            %{
              questions: [
                %{
                  question: "Ship the refund change today?",
                  options: [%{label: "Yes"}, %{label: "No"}]
                }
              ]
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, asked), response_text(asked)
        {:ok, context}
      end

      # Since v2.0.372 a crash is restarted by the agent's Keeper and main is not
      # woken for it; main is told when the harness gives up on the agent, which
      # is what "dies" means for a teammate now.
      when_ "the coder's harness gives up on its crashing process", context do
        {_copy, socket} =
          join_working_copy_socket(context, context.coder.working_copy, "coder's copy",
            working_copy_id: context.coder.working_copy_id
          )

        :ok = agent_down(socket, context.coder.id, "gave_up: ** (EXIT) killed")

        {:ok, context}
      end

      then_ "main is told, naming the teammate", context do
        main_id = context.main.id
        coder_id = context.coder.id

        # `notify_main` always dispatches (`Transport.dispatch_message`),
        # whether or not main currently holds a turn open; a separate,
        # unrelated work-offer sweep may also wake main with the generic
        # prompt since it is idle, but that is not this criterion's message.
        assert_receive {:agent_dispatch, ^main_id, ref, text}, 2_000
        assert is_binary(ref)

        assert text =~ coder_id or text =~ String.slice(coder_id, 0, 8),
               "main was told something, but not which teammate died:\n#{text}"

        {:ok, context}
      end
    end
  end
end
