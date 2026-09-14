defmodule CodeMySpecSpex.Story1047.Criterion3186Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3186 — The main agent with nothing assigned is left alone too.

  "Too" is the word doing the work. The main agent is the one most likely to be
  exempted — it is the project's own agent, it is always there, it is the one
  somebody talks to — and every one of those is a reason to keep it awake that
  has nothing to do with whether it has anything to do.

  It is also the most expensive one to keep awake. It runs continuously by
  design and `MainAgent.ensure_cadence/1` wakes it on a timer already, so a
  menu on every stop is a turn every stop, forever, on a project where nothing
  is happening.

  Same two Thens as 3181, against the agent the exemption would be written for.
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

  spex "An agent with nothing to do is sent nothing, the main agent included" do
    scenario "The main agent with nothing assigned is left alone too" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a main agent with no assigned work available", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        context = context |> start_session() |> put_to_work()

        {:ok,
         context
         |> Map.put(:main, main.id)
         |> Map.put(:before, heard_count(context, main.id))}
      end

      when_ "it ends a turn", context do
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

      then_ "it receives no menu", context do
        refute inspect(context.response) =~ "get_next_requirement",
               """
               The main agent was handed the menu with nothing assigned.

               It runs continuously and its cadence already wakes it on a
               timer, so a menu on every stop is a turn on every stop, forever,
               on a project where nothing is happening.

               #{inspect(context.response)}
               """

        {:ok, context}
      end

      then_ "and it is not asked to continue working", context do
        refute_told_anything(
          context,
          context.main,
          context.before,
          """
          The main agent was sent a message with nothing behind it.

          It is the agent most likely to be exempted from this rule — it is the
          project's own, it is always there, it is the one somebody talks to —
          and every one of those is a reason to keep it awake that has nothing
          to do with whether it has anything to do.
          """
        )

        {:ok, context}
      end
    end
  end
end
