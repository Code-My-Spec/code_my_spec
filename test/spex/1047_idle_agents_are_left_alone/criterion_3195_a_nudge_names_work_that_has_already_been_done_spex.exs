defmodule CodeMySpecSpex.Story1047.Criterion3195Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3195 — A nudge names work that has already been done.

  Every other criterion here is about whether the nudge is sent. This one is
  about a nudge that was correct when it was sent and is stale by the time it
  is read, which cannot be designed away: the graph moves between the decision
  and the turn, and a nudge racing a promote is the ordinary case rather than a
  bug.

  So the claim is about what the agent does with it, and the third Then is the
  one that matters. An agent told to promote work that has already landed finds
  nothing — and the failure mode is not that it errors, it is that it looks for
  something else to do. It was woken, so there must be work; it is a capable
  agent, so it finds some. That is how a stale doorbell turns into unrequested
  changes on a checkout, and it is worse than the spent turn this whole story
  is about.

  "It is allowed to stop" is the remedy in one line: finding nothing has to be
  a complete and acceptable answer.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.IdleAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Finding nothing to do is a complete answer" do
    scenario "A nudge names work that has already been done" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent nudged to promote its work", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        story = Fixtures.released_story(context.scope, "Refunds reach the ledger")
        context = context |> start_session() |> put_to_work()

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:story, story)}
      end

      given_ "that work has already landed", context do
        Fixtures.record_deploy(context.scope, context.story.id, "dev")

        {:ok, Map.put(context, :before, heard_count(context, context.coding))}
      end

      when_ "the agent looks at the named work", context do
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

      then_ "it finds nothing to do", context do
        refute inspect(context.response) =~ "promote",
               """
               The agent is still being pointed at work that has already
               landed.

               A nudge going stale between the decision and the turn is the
               ordinary case, not a bug — but reading it against a graph that
               has moved has to produce nothing, not the same instruction
               again.

               #{inspect(context.response)}
               """

        {:ok, context}
      end

      then_ "and it is allowed to stop", context do
        refute inspect(context.response) =~ ~r/"decision"\s*=>\s*"block"/,
               """
               The agent is held open over work that is already done, so it
               cannot end its turn by finding nothing.

               #{inspect(context.response)}
               """

        {:ok, context}
      end

      then_ "and it does not invent work to fill the turn", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          Having found the named work already done, the agent was handed
          something else.

          This is the expensive failure on this criterion. The agent was woken,
          so there must be work; it is capable, so it finds some — and a stale
          doorbell becomes unrequested changes on a checkout. Finding nothing
          has to be a complete answer.
          """
        )

        {:ok, context}
      end
    end
  end
end
