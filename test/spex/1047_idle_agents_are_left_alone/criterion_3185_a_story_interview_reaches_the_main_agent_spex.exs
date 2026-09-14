defmodule CodeMySpecSpex.Story1047.Criterion3185Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3185 — A story interview reaches the main agent.

  The third separation this story makes. 3179 separates roles, 3184 separates
  checkouts, and this separates the main agent from the copies: shaping work —
  a story that needs its interview — belongs to the main agent, and the agents
  on the working copies cannot do it at all.

  It matters more than the other two because of who is left holding it. A
  shaping item that wakes the copies wakes agents that will read it, find no
  requirement they can act on, and stop — while the main agent, the one that
  could have done it, is told nothing and stays quiet. The work is reachable by
  exactly one agent and gets offered to every other one.

  Asserted on the main agent's own stop reply, because that is the menu it
  reads.
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

  spex "Shaping work reaches the main agent and nobody else" do
    scenario "A story interview reaches the main agent" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a main agent and a coding agent on a working copy", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()

        {:ok,
         context
         |> Map.put(:main, main.id)
         |> Map.put(:coding, coding.id)
         |> Map.put(:coding_before, heard_count(context, coding.id))}
      end

      given_ "a story that needs its initial interview and no other work available", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the main agent ends a turn", context do
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

      then_ "its stop hook menu names the story interview", context do
        body = inspect(context.response)

        assert body =~ ~r/(interview|shape|story)/i,
               """
               The only work available is shaping work, and the main agent's
               menu does not mention it — so the one agent that can do it is
               not told it exists.

               #{body}
               """

        {:ok, context}
      end

      then_ "and the agents on the working copies are sent nothing", context do
        refute_told_anything(
          context,
          context.coding,
          context.coding_before,
          """
          A working-copy agent was woken by shaping work it cannot do.

          It will read the graph, find no requirement it can act on, and stop.
          Meanwhile the main agent — the one that could have done it — is the
          one that was told nothing.
          """
        )

        {:ok, context}
      end
    end
  end
end
