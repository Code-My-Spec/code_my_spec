defmodule CodeMySpecSpex.Story1048.Criterion3191Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3191 — Work arriving mid-turn is found at the stop hook.

  The wake is not an interrupt. An agent part-way through a turn has a tool
  call in flight and a plan it is following, and work arriving does not make
  either of those stale — it makes them *not last*.

  "Not interrupted" is worth asserting because interrupting is the natural
  reading of a doorbell. Every other criterion on this story is about the
  message arriving promptly, and promptness against a busy agent means either
  waiting or cutting in.

  So the promptness is delivered at the seam that already exists. The stop hook
  fires when the turn ends and its reply is already the menu, so work that
  arrived during the turn is named there — no interrupt, no queue, and no
  second message beside the reply, which is story 1047's 3196.
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

  spex "A wake is delivered at the end of a turn, never into the middle of one" do
    scenario "Work arriving mid-turn is found at the stop hook" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent part way through a turn", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()

        :ok = Fixtures.start_turn(context.scope, coding.id)
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "new coding work appears on its working copy", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.mark_story_ready(context.scope, story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :story, story)}
      end

      then_ "the agent is not interrupted", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          The agent was spoken to in the middle of a turn.

          Interrupting is the natural reading of a doorbell, and it is the
          wrong one: the agent has a tool call in flight and a plan it is
          following, and work arriving does not make either stale — it makes
          them not last.
          """
        )

        {:ok, context}
      end

      then_ "and the work is named in its stop hook menu when the turn ends", context do
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

        assert inspect(response) =~ "get_next_requirement",
               """
               Work appeared during the turn and the menu at the end of it does
               not mention any.

               Not interrupting is only acceptable because the seam at the end
               of the turn already exists and the reply there is already the
               menu. Without that, "do not interrupt" means the work waits for
               whatever wakes the agent next, which may be nothing.

               #{inspect(response)}
               """

        {:ok, context}
      end
    end
  end
end
