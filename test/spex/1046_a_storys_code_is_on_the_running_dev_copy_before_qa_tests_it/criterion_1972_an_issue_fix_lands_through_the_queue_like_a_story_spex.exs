defmodule CodeMySpecSpex.Story1046.Criterion1972Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1972 — An issue fix lands through the queue like a story.

  Rule: a team's fix for its issue reaches main the way a story's work does —
  queued from the team's copy, gated with main beneath it, landed by the queue
  — and the queue names the issue when it reports the outcome.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
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

  spex "An issue fix lands through the queue like a story", criterion: 1972 do
    scenario "a QA-passed fix, from a copy main has moved past" do
      given_ "a team's fix that QA has passed", context do
        context =
          context
          |> a_promotable_project()
          |> an_issue_assigned_to_the_team()
          |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())
          |> qa_passes_it()

        {:ok, context}
      end

      given_ "main has moved on since the team's branch left it", context do
        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the coder promotes the fix", context do
        {:ok, Map.put(context, :answer, the_coder_promotes_it(context))}
      end

      then_ "it is queued, naming the issue", context do
        assert context.answer =~ "Queued for promotion", context.answer
        assert context.answer =~ "issue #{context.issue_id}", context.answer
        {:ok, context}
      end

      when_ "the gate certifies it on main and the queue lands it", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :told, what_was_told(context.coder.id))}
      end

      then_ "the coder is told the issue's fix landed", context do
        assert context.told =~ "the fix for issue #{context.issue_id}", context.told
        assert context.told =~ "landed on main", context.told
        {:ok, context}
      end

      then_ "main holds the fix and main's own work together", context do
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/notify.ex")
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/treaty.ex")
        {:ok, context}
      end
    end
  end

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"
end
