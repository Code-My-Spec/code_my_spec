defmodule CodeMySpecSpex.Story1046.Criterion1965Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1965 — A slow gate or deployment does not become a slow promotion.

  Rule: neither the batch's analyzers nor the restart after a landing hold the
  agent's answer. `promote` answers on queueing; the landing message answers on
  the merge, with the deployment dispatched and not awaited.
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

  spex "A slow gate does not hold the promotion's answer", criterion: 1965 do
    scenario "the gate's analyzers have not answered" do
      given_ "a story branch main has moved past", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)

        {:ok, context}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "it is answered while the gate is still waiting on every analyzer", context do
        refute context.response.isError, response_text(context.response)
        assert response_text(context.response) =~ "Queued for promotion"
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)
        {:ok, context}
      end
    end
  end

  spex "A slow deployment does not hold the landing's answer", criterion: 1965 do
    scenario "the restart after the landing has not come back" do
      given_ "a story branch level with main, its analyzers current", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)

        {:ok, context}
      end

      when_ "the agent promotes, and the queue lands it", context do
        promote(context, context.story.number)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "it is told the work landed, and that the deployment is not yet confirmed",
            context do
        assert context.told =~ "landed on main", context.told

        assert context.told =~ ~r/not waited on|not yet confirmed|unconfirmed/,
               "the landing waited on, or claimed, a deployment nobody has answered. " <>
                 "Got: #{context.told}"

        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
