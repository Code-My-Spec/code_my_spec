defmodule CodeMySpecSpex.Story1059.Criterion1609Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 1609 — A continuous main agent gets one check-in turn every
  interval, with or without work; a main agent that is not continuous gets
  none.

  John, 2026-10-01: "Cadence is for continuous main agents only. They should
  be woke every 20 minutes, converge the content of both paths." The tick is
  one turn carrying the check-in, whether or not the graph holds work for main.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.Cadence
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp let_the_interval_pass(context) do
    changed_at = DateTime.utc_now()
    {:reply, response, _} = Cadence.execute(%{seconds: 1}, frame(context))
    refute response.isError, response_text(response)

    Fixtures.await_recovery_check(
      fn ->
        {:reply, report, _} = Cadence.execute(%{}, frame(context))
        response_text(report)
      end,
      changed_at
    )

    context
  end

  spex "A continuous main agent gets one check-in turn every interval, with or without work; a main agent that is not continuous gets none",
    criterion: 1609 do
    scenario "A continuous main with no work still gets its check-in" do
      given_ "a continuous main agent with no work, on a running timer", context do
        context = given_a_staffed_checkout(context, "spex_1609")
        context = FullSatisfactionFixtures.apply(context)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)

        assert Fixtures.role_queue_size(context.scope, main.id) == 0,
               "the premise is a main with no work for it"

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)

        {:reply, configured, _} = Cadence.execute(%{seconds: 30}, frame(context))
        refute configured.isError, response_text(configured)
        :ok = Fixtures.start_recovery_timer(context.scope)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "the interval passes", context do
        context = let_the_interval_pass(context)
        HeldProvider.await_request(5_000)
        {:ok, context}
      end

      then_ "main is taking exactly one turn, and it is the check-in", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.main_id)
        [request] = HeldProvider.seen()
        assert Jason.decode!(request)["messages"] |> Jason.encode!() =~ "Check-in."
        {:ok, context}
      end
    end
  end

  spex "A main agent that is not continuous gets nothing from the timer", criterion: 1609 do
    scenario "A main outside the loop takes no turn when the interval passes" do
      given_ "a main agent that is not continuous, with no work, on a running timer", context do
        context = given_a_staffed_checkout(context, "spex_1609")
        context = FullSatisfactionFixtures.apply(context)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)

        assert Fixtures.role_queue_size(context.scope, main.id) == 0,
               "the premise is a main with no work for it"

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)

        {:reply, configured, _} = Cadence.execute(%{seconds: 30}, frame(context))
        refute configured.isError, response_text(configured)
        :ok = Fixtures.start_recovery_timer(context.scope)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "the interval passes", context do
        {:ok, let_the_interval_pass(context)}
      end

      then_ "main takes no turn", context do
        # The machine accepts a turn before the tick returns, so this is
        # observable at once.
        assert {:ok, %{busy?: false}} = Machine.status(context.main_id),
               "the timer gave a main outside the loop a turn"

        {:ok, context}
      end
    end
  end
end
