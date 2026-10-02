defmodule CodeMySpecSpex.Story988.Criterion1679Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 1679 — An analysis run waiting for a slot reads as queued, distinct
  from one that is executing.

  A run is `:running` from the moment it is requested, and the harness runs one
  analyzer at a time machine-wide, so a compiler run sat nineteen minutes behind
  seven others and read as hung (run 54245, bf627680). The harness reports when
  an analyzer actually begins; until it does, the run is queued, and the stop
  hook says which.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy_socket: 4]

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An analysis run waiting for a slot reads as queued, distinct from one that is executing",
    criterion: 1679 do
    scenario "the harness has begun spex, and compiler waits behind it" do
      given_ "a harness serving this checkout, asked for compiler and spex", context do
        {:ok, root} = Briefly.create(directory: true)

        {_reply, socket} =
          join_working_copy_socket(context, root, "this checkout",
            working_copy_id: context.scope.active_working_copy_id
          )

        {:ok,
         Map.merge(context, %{
           socket: socket,
           compiler: Fixtures.start_analysis_run(context.scope, "compiler"),
           spex: Fixtures.start_analysis_run(context.scope, "spex")
         })}
      end

      when_ "the harness reports spex has begun, and the agent stops", context do
        ref =
          Phoenix.ChannelTest.push(context.socket, "analysis_started", %{
            "run_id" => context.spex.id,
            "start_commit" => String.duplicate("a", 40),
            "start_tree_dirty" => false
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{
            "session_id" => "spex-#{System.unique_integer([:positive])}"
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :said, response["systemMessage"] || response["reason"] || "")}
      end

      then_ "compiler reads as queued, and spex as running", context do
        assert context.said =~ "compiler (queued for a slot)",
               "a run waiting for a slot must say so, or it reads as hung: #{context.said}"

        assert context.said =~ "spex"

        refute context.said =~ "spex (queued",
               "spex has begun; calling it queued is the opposite mistake: #{context.said}"

        {:ok, context}
      end
    end
  end
end
