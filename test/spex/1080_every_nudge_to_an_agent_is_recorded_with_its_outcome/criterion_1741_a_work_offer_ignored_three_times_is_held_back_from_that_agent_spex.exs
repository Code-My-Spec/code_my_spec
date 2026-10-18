defmodule CodeMySpecSpex.Story1080.Criterion1741Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1741 — A work offer ignored three times is held back from that agent
  only, and main is told.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Work ignored three times is held back and main hears", criterion: 1741 do
    scenario "a coder ignores the same work three turns running" do
      given_ "a coder offered work, mid-turn, and a main", context do
        context = offered_work(context)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "it ends three turns without taking it", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)

        for _ <- 1..2 do
          assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
          :ok = Fixtures.put_agent_mid_turn(context.scope, id)
          :ok = Fixtures.end_turn(context.scope, id)
        end

        {:ok, context}
      end

      then_ "it is not offered that work a fourth time", context do
        id = context.coder
        refute_receive {:work_turn_requested, ^id, _ref, _prompt}, 1_000

        # Main's correction (a01ffadb, refined on 21eb9860): the third
        # ignore reaches the ladder's last rung and settles :open, not
        # :ignored -- it stays open, held back, until main acts. Two
        # rungs climbed and settled :ignored (attempts 1 and 2), the third
        # left open: still three attempts, still not pushed a fourth time.
        assert [_, _] = offers(context, id, %{kind: "work", status: "ignored"}),
               listing(context)

        assert [_] = offers(context, id, %{kind: "work", status: "open"}),
               listing(context)

        {:ok, context}
      end

      then_ "and main is told it was held back", context do
        assert Enum.any?(
                 offers(context, context.main_id, %{kind: "stalled"}),
                 &Enum.any?(&1.messages, fn m ->
                   m =~ "Held back from the coding agent #{context.coder}"
                 end)
               ),
               listing(context)

        {:ok, context}
      end
    end
  end
end
