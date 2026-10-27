defmodule CodeMySpecSpex.Story1046.Criterion1966Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1966 — A candidate is certified against the queue head.

  Rule: a candidate does not have to merge main itself first. The gate merges
  it onto main as it will be when the candidates ahead of it have landed, and
  certifies that tree.
  """

  use CodeMySpecSpex.Case

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

  spex "A candidate is certified against the queue head", criterion: 1966 do
    scenario "a second candidate is gated with the first one's work beneath it" do
      given_ "two agents' branches from the same main, which has since moved on", context do
        context =
          context
          |> a_promotable_project()
          |> an_agent_on_the_copy()
          |> another_candidate(:second)

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        commit_work(context, context.second.root, "lib/broken_oaths/diplomacy/oath.ex", oath())

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        its_analyzers_are_current(context, context.second)

        {:ok, context}
      end

      when_ "both promote, the first ahead of the second", context do
        promote(context, context.story.number)
        {:ok, Map.put(context, :second_response, promote_from(context.second, nil))}
      end

      then_ "the second is told it is behind the first in the queue", context do
        assert response_text(context.second_response) =~ "position 2",
               response_text(context.second_response)

        {:ok, context}
      end

      when_ "the first is gated clean and lands", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :first_told, what_the_agent_was_told(context))}
      end

      when_ "the gate takes up the second", context do
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)
        {:ok, context}
      end

      then_ "the tree it certifies holds main, the first's work, and the second's", context do
        assert context.first_told =~ "landed on main", context.first_told

        for file <- ~w(treaty.ex peace.ex oath.ex) do
          assert exists?(context.gate_root, "lib/broken_oaths/diplomacy/#{file}"),
                 "the second candidate was not gated on the queue head: #{file} is missing"
        end

        {:ok, context}
      end

      when_ "that tree is gated clean", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :second_told, what_was_told(context.second.agent_id))}
      end

      then_ "the second lands on top of the first", context do
        assert context.second_told =~ "landed on main", context.second_told
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex")
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/oath.ex")
        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"

  defp oath,
    do: "defmodule BrokenOaths.Diplomacy.Oath do\n  def swear, do: :sworn\nend\n"
end
