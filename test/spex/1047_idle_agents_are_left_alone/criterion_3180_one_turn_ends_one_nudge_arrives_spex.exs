defmodule CodeMySpecSpex.Story1047.Criterion3180Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3180 — One turn ends, one nudge arrives.

  The stop hook's reply is the menu, and it is already a message the agent
  reads. Anything else sent at the same moment is a second one, arriving in the
  same turn, saying a version of the same thing — and the model reads both.

  The cost is per turn, which is what makes it worth a criterion. A coding
  agent ending fifty turns in a session pays for the duplicate fifty times, and
  the duplicate is the least useful token in the turn: it restates what the
  reply it arrived beside already said.

  Asserted as a count rather than by matching the text, because the failure is
  "more than one" and any particular wording is something the next change can
  legitimately alter.
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
    scenario "One turn ends, one nudge arrives" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :context_spec_task_started

      given_ "a coding agent with coding work remaining", context do
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

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent receives the stop hook menu", context do
        assert context.response,
               "the stop produced no reply at all, so there is no menu for a second " <>
                 "message to arrive beside"

        {:ok, context}
      end

      then_ "and it receives no other message about continuing", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          A second message arrived beside the stop reply.

          The reply is already the menu and the agent reads both, so this is a
          duplicate paid for on every turn — fifty times in a working session,
          each one restating what it arrived next to.
          """
        )

        {:ok, context}
      end
    end
  end
end
