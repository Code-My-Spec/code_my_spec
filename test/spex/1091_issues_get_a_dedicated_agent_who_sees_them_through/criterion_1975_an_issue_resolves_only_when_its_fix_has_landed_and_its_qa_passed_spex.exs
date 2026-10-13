defmodule CodeMySpecSpex.Story1091.Criterion1975Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1975 — An issue resolves only when its fix has landed and its QA passed.

  Rule: neither fact alone resolves an issue. A fix QA has not passed is not
  promoted — the queue refuses it, naming what is missing — and a fix QA has
  passed stays unresolved until the queue lands it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A fix QA has not passed is not promoted", criterion: 1975 do
    scenario "the coder promotes before QA has tested the fix" do
      given_ "a team whose coder has fixed its assigned issue", context do
        context =
          context
          |> a_promotable_project()
          |> an_issue_assigned_to_the_team()
          |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())

        {:ok, analyzers_are_current(context)}
      end

      when_ "the coder promotes from its copy", context do
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "it is refused, naming the QA it is missing", context do
        text = response_text(context.response)
        assert context.response.isError, "a fix QA had not passed was queued: #{text}"
        assert text =~ "issue #{context.issue_id}", text
        assert text =~ "has not passed QA", text
        {:ok, context}
      end

      then_ "the issue is not resolved", context do
        refute the_issue(context) =~ "**Status:** resolved"
        {:ok, context}
      end
    end
  end

  spex "A fix QA has passed is not resolved until it lands", criterion: 1975 do
    scenario "the fix waits in the gate" do
      given_ "a team's fix that QA has passed, from a copy main has moved past", context do
        context =
          context
          |> a_promotable_project()
          |> an_issue_assigned_to_the_team()
          |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())
          |> qa_passes_it()

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the coder promotes it, and the gate has not answered", context do
        the_coder_promotes_it(context)
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)
        {:ok, context}
      end

      then_ "the issue is not resolved", context do
        refute the_issue(context) =~ "**Status:** resolved",
               "an issue resolved before its fix reached main"

        {:ok, context}
      end

      when_ "the gate certifies it and the queue lands it", context do
        the_gate_answers(context)
        assert what_was_told(context.coder.id) =~ "landed on main"
        {:ok, context}
      end

      then_ "the issue is resolved", context do
        assert the_issue(context) =~ "**Status:** resolved"
        {:ok, context}
      end
    end
  end

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"
end
