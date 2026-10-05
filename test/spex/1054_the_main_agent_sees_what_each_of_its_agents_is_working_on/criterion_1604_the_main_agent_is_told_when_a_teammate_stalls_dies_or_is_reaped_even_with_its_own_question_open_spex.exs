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

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
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

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Ship the refund change today?",
                  options: [%{label: "Yes"}, %{label: "No"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        {:ok, context}
      end

      when_ "the coder's process dies", context do
        :ok =
          CodeMySpec.Agents.record_turn_event(context.scope, context.coder.id, %{
            "kind" => "agent_died",
            "text" => "** (EXIT) killed"
          })

        {:ok, context}
      end

      then_ "main is told, naming the teammate", context do
        main_id = context.main.id
        coder_id = context.coder.id

        # Main is idle (blocked on its own open question), not mid-turn, so
        # waking it for this starts a new turn (`request_work_turn`) rather
        # than dispatching into one already running (`dispatch_message`).
        assert_receive {:work_turn_requested, ^main_id, ref, text}, 2_000
        assert is_binary(ref)

        assert text =~ coder_id or text =~ String.slice(coder_id, 0, 8),
               "main was told something, but not which teammate died:\n#{text}"

        {:ok, context}
      end
    end
  end
end
