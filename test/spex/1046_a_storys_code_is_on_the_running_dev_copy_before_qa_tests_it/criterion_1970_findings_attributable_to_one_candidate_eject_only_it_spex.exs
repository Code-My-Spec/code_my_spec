defmodule CodeMySpecSpex.Story1046.Criterion1970Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1970 — Findings attributable to one candidate eject only it.

  Rule: when every finding against a red batch is in files only one candidate
  changed, that candidate is taken out and the rest are gated again without
  it. When the findings cannot be pinned on one candidate, the batch is split
  and its first half gated alone.

  A batch of two needs both candidates waiting together, so a third agent's
  promotion holds the gate while they queue behind it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Findings attributable to one candidate eject it", criterion: 1970 do
    scenario "both findings are in the file only the second candidate changed" do
      given_ "two candidates queued together behind a third", context do
        {:ok, two_queued_together(context)}
      end

      when_ "their batch is gated, and credo finds two problems in the second's file", context do
        the_gate_answers(context, %{
          "credo" => [
            io_inspect("lib/broken_oaths/diplomacy/oath.ex", 2),
            io_inspect("lib/broken_oaths/diplomacy/oath.ex", 3)
          ]
        })

        {:ok, Map.put(context, :second_told, what_was_told(context.second.agent_id))}
      end

      then_ "the second is taken out with those findings", context do
        assert context.second_told =~ "taken out of the queue", context.second_told
        assert context.second_told =~ "oath.ex:2", context.second_told
        {:ok, context}
      end

      then_ "the first is gated again without it", context do
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)
        assert exists?(context.gate_root, "lib/broken_oaths/diplomacy/accord.ex")

        refute exists?(context.gate_root, "lib/broken_oaths/diplomacy/oath.ex"),
               "the second candidate is still in the batch"

        {:ok, context}
      end

      when_ "that is gated clean", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :first_told, what_was_told(context.first.agent_id))}
      end

      then_ "the first lands and the second does not", context do
        assert context.first_told =~ "landed on main", context.first_told
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/accord.ex")
        refute exists?(context.running_root, "lib/broken_oaths/diplomacy/oath.ex")
        {:ok, context}
      end
    end
  end

  spex "Findings that cannot be pinned on one candidate bisect the batch", criterion: 1970 do
    scenario "both findings are in a file neither candidate changed" do
      given_ "two candidates queued together behind a third", context do
        {:ok, two_queued_together(context)}
      end

      when_ "their batch is gated, and credo finds two problems in War", context do
        the_gate_answers(context, %{
          "credo" => [
            io_inspect("lib/broken_oaths/diplomacy/war.ex", 2),
            io_inspect("lib/broken_oaths/diplomacy/war.ex", 3)
          ]
        })

        {:ok, context}
      end

      then_ "the first half of the batch is gated alone", context do
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)
        assert exists?(context.gate_root, "lib/broken_oaths/diplomacy/accord.ex")

        refute exists?(context.gate_root, "lib/broken_oaths/diplomacy/oath.ex"),
               "the batch was gated whole again instead of split"

        {:ok, context}
      end
    end
  end

  # A third agent's candidate, behind main, holds the gate; the first and second
  # promote while it does, so they are batched together once it lands.
  defp two_queued_together(context) do
    context =
      context
      |> a_promotable_project()
      |> an_agent_on_the_copy()
      |> another_candidate(:first)
      |> another_candidate(:second)

    commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
    commit_work(context, context.first.root, "lib/broken_oaths/diplomacy/accord.ex", accord())
    commit_work(context, context.second.root, "lib/broken_oaths/diplomacy/oath.ex", oath())
    commit_work(context, context.running_root, "lib/broken_oaths/diplomacy/treaty.ex", treaty())
    analyzers_are_current(context)

    story = a_promotable_story(context)
    promote(context, story.number)
    assert the_gate_is_running(context) == ~w(compiler credo exunit spex)

    assert response_text(promote_from(context.first, nil)) =~ "position"
    assert response_text(promote_from(context.second, nil)) =~ "position"

    the_gate_answers(context)
    assert what_the_agent_was_told(context) =~ "landed on main"
    context
  end

  # Credo's own JSON keys, as a harness relays them; a high-priority warning.
  defp io_inspect(file, line),
    do: %{
      "filename" => file,
      "line_no" => line,
      "priority" => 10,
      "category" => "warning",
      "check" => "Credo.Check.Warning.IoInspect",
      "message" => "There should be no calls to `IO.inspect/1`."
    }

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"

  defp accord,
    do: "defmodule BrokenOaths.Diplomacy.Accord do\n  def reach, do: :reached\nend\n"

  defp oath,
    do: "defmodule BrokenOaths.Diplomacy.Oath do\n  def swear, do: :sworn\nend\n"
end
