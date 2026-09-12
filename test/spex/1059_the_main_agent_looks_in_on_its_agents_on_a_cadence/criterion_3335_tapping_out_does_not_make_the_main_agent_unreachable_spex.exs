defmodule CodeMySpecSpex.Story1059.Criterion3335Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3335 — Tapping out does not make the main agent unreachable.

  Rule: standing down silences the timer, not the door.

  3334's necessary companion, and the criterion that makes standing down safe to
  build. Without it the honest implementation of "the cadence stops" is "the
  main agent stops", and a project whose agents have all finished acquires an
  unreachable main agent — which is fine right up to the moment somebody starts
  work again, at which point the first question raised goes nowhere and the
  agent that asked waits forever.

  That failure has no symptom on the main agent's side. It is not woken, which
  is what it asked for; the question simply does not arrive, and the asking
  agent cannot tell the difference between "nobody has got to it" and "nobody
  ever will".

  ## What the scenario proves

  The main agent has tapped out and the cadence is stopped — 3334's end state,
  reached the same way. A question raised after that still reaches it. Nothing
  ticks, so if it arrives it arrived by the push.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A stood-down main agent can still be reached" do
    scenario "an agent asks after the cadence has stopped" do
      given_ "a main agent that has tapped out", context do
        reply = join_working_copy(context, "/tmp/spex-3335", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main =
          Fixtures.running_agent(scope,
            role: "main",
            working_copy: "/tmp/spex-3335",
            continuous: true
          )

        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3335")

        frame = %Frame{assigns: %{current_scope: scope, agent_id: main.id}}
        {:reply, tapped, _frame} = TapOut.execute(%{}, frame)

        refute tapped.isError, inspect(tapped)

        refute Fixtures.cadence_running?(scope),
               "the premise is a stopped cadence — 3334's end state, reached the same way"

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:coding, coding)}
      end

      when_ "an agent asks a question", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coding.id}
        }

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              title: "asked after the main agent stood down",
              questions: [
                %{
                  "question" => "Which branch does this land on?",
                  "options" => [%{"label" => "main"}, %{"label" => "a branch"}]
                }
              ]
            },
            frame
          )

        refute response.isError, inspect(response)

        # Nothing ticks. If it arrives, it arrived by the push.
        {:ok, context}
      end

      then_ "the question still reaches the main agent", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        assert html =~ "Which branch does this land on?",
               """
               The main agent stood down and became unreachable with it.

               Without this criterion the honest implementation of "the cadence
               stops" is "the main agent stops" — fine until somebody starts
               work again, at which point the first question raised goes nowhere
               and the agent that asked waits forever.

               The failure has no symptom on the main agent's side: it is not
               woken, which is what it asked for. The asking agent cannot tell
               "nobody has got to it" from "nobody ever will".

               transcript:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
