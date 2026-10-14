defmodule CodeMySpecSpex.Story1080.Criterion1674Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1674 — A refused stop records a problems offer, and the turn-end
  menu records one menu offer per held task, each linked to the message sent.

  An agent ending a turn that broke the build is refused its stop and handed
  the problems. One ending a clean turn while holding a task is handed the
  menu: one offer, on the task it holds.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  @broken_build Path.expand("test/fixtures/validation/pipeline_compile_error/compile.jsonl")

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "The turn-end menu is one offer on the held task", criterion: 1674 do
    scenario "a coder holding a task ends a turn" do
      given_ "a continuous coder holding a task, mid-turn", context do
        context = coder_holding_a_task(context)
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        {:ok, context}
      end

      when_ "its turn ends", context do
        :ok = HarnessHooks.end_turn(context, context.coder)
        {:ok, Map.put(context, :sent, dispatched(context))}
      end

      then_ "one menu offer on its task, linked to the menu it was sent", context do
        assert [offer] = offers(context, context.coder, %{kind: "menu"}),
               "expected one menu offer:\n" <> listing(context)

        assert offer.subject == "menu:#{context.task_id}"
        assert offer.messages == [excerpt(context.sent)]
        {:ok, context}
      end
    end
  end

  spex "A refused stop is a problems offer", criterion: 1674 do
    scenario "a coder ends a turn on a build that its own edit broke" do
      given_ "a continuous coder holding a task, mid-turn, that edited a file", context do
        context = coder_holding_a_task(context)
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)

        HarnessHooks.write_file(
          context,
          "lib/example_context.ex",
          "defmodule ExampleContext do\n"
        )

        Fixtures.record_agent_edit(context.coder, "lib/example_context.ex")
        {:ok, context}
      end

      when_ "its turn ends with that file not compiling", context do
        HarnessHooks.land_analysis(context, "compiler", @broken_build)
        :ok = Fixtures.drain_background_work()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = HarnessHooks.end_turn(context, context.coder)

        id = context.coder

        assert_receive {:agent_dispatch, ^id, _ref,
                        "Fix these problems before stopping" <> _ = sent},
                       2_000

        {:ok, Map.put(context, :sent, sent)}
      end

      then_ "one problems offer on the problem set, linked to the refusal it was sent",
            context do
        refused =
          context
          |> offers(context.coder, %{kind: "problems"})
          |> Enum.filter(&String.starts_with?(&1.subject, "problem_set:"))

        assert [offer] = refused, "expected one refused-stop offer:\n" <> listing(context)
        assert offer.messages == [excerpt(context.sent)]
        {:ok, context}
      end
    end
  end

  defp dispatched(context) do
    id = context.coder
    assert_receive {:agent_dispatch, ^id, _ref, message}, 2_000
    message
  end
end
