defmodule CodeMySpecSpex.Story1047.Criterion3181Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3181 — A turn ends with nothing to do and nothing is sent.

  The story's own sentence: "I am not spending turns on stop hooks and messages
  with nothing behind them." This is the case where there is nothing behind
  them at all.

  Three Thens because there are three separate things that get sent to an agent
  with nothing to do, and each is a different author's idea of being helpful. A
  menu with no items on it. A note that the loop is still running. An
  encouragement to carry on. All three are read by the model, and all three
  invite the same reply — the agent looks for work, finds none, and stops
  again, having spent a turn to learn what the message could have said.

  Asserting all three against the same stop keeps them from being satisfied one
  at a time by moving the wording between them.
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

  spex "An agent with nothing to do is sent nothing" do
    scenario "A turn ends with nothing to do and nothing is sent" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent and a graph that holds no coding work", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()

        assert Fixtures.role_queue_size(context.scope, coding.id) == 0,
               """
               The premise is a graph with no coding work, and there is some —
               so this scenario would assert silence against an agent that
               should be spoken to, which is 3178's claim inverted.
               """

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

      then_ "the agent receives no menu", context do
        body = inspect(context.response)

        refute body =~ "get_next_requirement",
               """
               An agent with nothing to do was handed the menu anyway.

               It will call `get_next_requirement`, be told there is nothing,
               and stop — a whole turn spent learning what the menu could have
               left unsaid.

               #{body}
               """

        {:ok, context}
      end

      then_ "and it is not told the loop is still running", context do
        refute inspect(context.response) =~ ~r/(loop|still running|continuous)/i,
               """
               The agent was told the loop is running, which is a fact about
               machinery it does not act on and cannot change.

               #{inspect(context.response)}
               """

        {:ok, context}
      end

      then_ "and it is not asked to continue working", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          An agent with an empty queue was sent a message anyway.

          Each of these is somebody's idea of being helpful and each costs the
          same thing: the model reads it, looks for work, finds none, and stops
          — having spent a turn to learn what the message could have said.
          """
        )

        {:ok, context}
      end
    end
  end
end
