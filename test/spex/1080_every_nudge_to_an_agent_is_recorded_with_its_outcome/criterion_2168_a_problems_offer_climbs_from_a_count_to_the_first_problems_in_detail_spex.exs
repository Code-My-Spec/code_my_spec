defmodule CodeMySpecSpex.Story1080.Criterion2168Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2168 — A problems offer climbs from a count, to the first
  problems in detail.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.HarnessHooks, only: [land_analysis: 3, write_file: 3, end_turn: 2]

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @many_failures Path.expand("test/fixtures/validation/pipeline_exunit_many_failures/exunit.json")

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A problems offer's rungs climb from a count to detail", criterion: 2168 do
    scenario "a coder's edit leaves many outstanding problems" do
      given_ "a coder holding a task, mid-turn, that edited a file", context do
        context = coder_holding_a_task(context)
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        write_file(context, "lib/example_context.ex", "defmodule ExampleContext do\nend\n")
        Fixtures.record_agent_edit(context.coder, "lib/example_context.ex")
        {:ok, context}
      end

      when_ "its turn ends with many outstanding problems, and it ignores the first rung",
            context do
        land_analysis(context, "exunit", @many_failures)
        :ok = Fixtures.drain_background_work()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = end_turn(context, context.coder)

        id = context.coder
        first = next_problems_dispatch(id)
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung says how many problems there are to fix", context do
        assert context.first =~ "15 problems to fix", context.first
        {:ok, context}
      end

      when_ "it ignores that rung and ends another turn", context do
        :ok = end_turn(context, context.coder)
        second = next_problems_dispatch(context.coder)
        {:ok, Map.put(context, :second, second)}
      end

      then_ "the next rung gives the detail of the first few problems and says to fix them",
            context do
        assert context.second =~ "test/many_failures/case_01_test.exs", context.second
        {:ok, context}
      end
    end
  end

  # land_analysis's own real run completion also dispatches a generic "your
  # run finished" alert to the agent, ahead of the turn-end problems-offer
  # dispatch this scenario actually tests -- skip past anything that isn't
  # the ladder's own wording, within the same window.
  defp next_problems_dispatch(id, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agent_dispatch, ^id, _ref, text} ->
        matches? = text =~ "problems to fix" or text =~ "test/many_failures/case_01_test.exs"
        pick_problems_dispatch(matches?, text, id, deadline)
    after
      remaining -> flunk("no problems-offer dispatch for #{id} within the window")
    end
  end

  defp pick_problems_dispatch(true, text, _id, _deadline), do: text

  defp pick_problems_dispatch(false, _text, id, deadline),
    do: next_problems_dispatch(id, deadline)
end
