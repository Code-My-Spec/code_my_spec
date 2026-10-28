defmodule CodeMySpecSpex.Story1171.Criterion2541Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2541 — Main is told which run is stuck, how old it is and when it was last heard from.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Main receives the identity, source, copy, age and last event of a stuck run",
    criterion: 2541 do
    scenario "spex run 64421 on team B's copy is 31 minutes old and 12 minutes silent" do
      given_ "run 64421 is unfinished on team B's copy", context do
        run =
          Fixtures.start_analysis_run(context.scope, "spex",
            run_number: 64_421,
            working_copy_name: "team B's copy",
            started_minutes_ago: 31
          )

        :ok = Fixtures.set_last_analysis_event(context.scope, run.id, minutes_ago: 12)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      when_ "the run is found stuck", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, _body} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        {:ok, context}
      end

      then_ "Main is told the run, source, copy, age and last event", context do
        messages = Fixtures.main_stuck_notifications(context.scope)

        assert Enum.any?(messages, fn message ->
                 Enum.all?(
                   ["64421", "spex", "team B's copy", "31 minutes", "12 minutes"],
                   &String.contains?(message, &1)
                 )
               end)

        {:ok, context}
      end
    end
  end
end
