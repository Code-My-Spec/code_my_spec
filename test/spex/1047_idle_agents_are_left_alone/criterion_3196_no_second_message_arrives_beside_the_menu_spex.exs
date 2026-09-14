defmodule CodeMySpecSpex.Story1047.Criterion3196Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3196 — No second message arrives beside the menu.

  3180 says one nudge per turn. This names the two messages that actually
  arrive beside it, because each was added separately, each is individually
  defensible, and neither reads as a duplicate to whoever added it.

  "Your turn is done and the loop is still running" tells the agent something
  it cannot act on — it does not decide whether the loop runs. "Your task is
  still open" tells it something the menu it arrived with already says, in the
  line above.

  Together they turn one message into three, on every turn, for as long as the
  agent works. They are named individually here so that removing one does not
  look like satisfying the criterion.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The stop reply is the whole of what an agent is told when its turn ends" do
    scenario "No second message arrives beside the menu" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :context_spec_task_started

      given_ "a coding agent with an open task", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = put_to_work(context)

        # Mid-turn, which is the premise rather than a detail: this criterion is
        # about what an agent gets when *its own* turn ends, and a wake is never
        # delivered to an agent that is working. Without the turn in flight the
        # scenario describes an idle agent being told about somebody else's
        # completion, which is criterion 3108 of story 538 and the opposite
        # claim.
        :ok = Fixtures.put_agent_mid_turn(context.scope, coding.id)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "the stop decision is made", context do
        response =
          use_cmd_cassette "clean", record: :none do
            context.conn
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => clean_analysis()
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok,
         context
         |> Map.put(:response, response)
         |> Map.put(:said, said_since(context, context.coding, context.before))}
      end

      then_ "it receives the menu once", context do
        assert context.response, "the stop produced no reply, so there is no menu"

        assert length(context.said) <= 1,
               """
               #{length(context.said)} messages arrived beside the stop reply.

               Each was added separately and each is individually defensible,
               which is how one message becomes three on every turn for as long
               as the agent works.

               #{Enum.join(context.said, "\n---\n")}
               """

        {:ok, context}
      end

      then_ "and it is not also told its turn is done and the loop is still running", context do
        refute Enum.any?(context.said, &(&1 =~ ~r/(loop is still running|turn is done)/i)),
               """
               The agent was told its turn is done and the loop is running.

               It cannot act on either: it does not decide whether the loop
               runs, and it already knows its turn ended — it ended it.

               #{Enum.join(context.said, "\n---\n")}
               """

        {:ok, context}
      end

      then_ "and it is not also told separately that its task is still open", context do
        refute Enum.any?(context.said, &(&1 =~ ~r/(task is still open|still has an open task)/i)),
               """
               The agent was told separately that its task is open — which the
               menu it arrived beside already says, in the line above.

               Named as its own Then so that removing the other message does
               not look like satisfying this criterion.

               #{Enum.join(context.said, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
