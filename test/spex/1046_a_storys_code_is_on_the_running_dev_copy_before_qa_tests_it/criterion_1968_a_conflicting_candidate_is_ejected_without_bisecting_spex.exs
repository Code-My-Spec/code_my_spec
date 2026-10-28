defmodule CodeMySpecSpex.Story1046.Criterion1968Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1968 — A conflicting candidate is ejected without bisecting.

  Rule: a candidate that does not merge onto the queue head is taken out as
  soon as the merge fails, naming the files, and no analyzer is spent on it.
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

  spex "A conflicting candidate is ejected without bisecting", criterion: 1968 do
    scenario "a second agent changed the line the first agent's landed work changed" do
      given_ "two agents' branches that change the same line of War", context do
        context =
          context
          |> a_promotable_project()
          |> an_agent_on_the_copy()
          |> another_candidate(:second)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":first")
        )

        commit_work(
          context,
          context.second.root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":second")
        )

        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        its_analyzers_are_current(context, context.second)

        {:ok, context}
      end

      given_ "the first agent's work has landed", context do
        promote(context, context.story.number)
        assert what_the_agent_was_told(context) =~ "landed on main"
        {:ok, context}
      end

      when_ "the second agent promotes", context do
        promote_from(context.second, nil)
        {:ok, Map.put(context, :told, what_was_told(context.second.agent_id))}
      end

      then_ "it is taken out, naming the file that conflicts", context do
        assert context.told =~ "taken out of the queue", context.told
        assert context.told =~ "lib/broken_oaths/diplomacy/war.ex", context.told
        {:ok, context}
      end

      then_ "no analyzer was run on it", context do
        join_ref = context.gate_socket.join_ref

        refute_received %Phoenix.Socket.Message{event: "run_analysis", join_ref: ^join_ref},
                        "the gate analyzed a candidate that could not even be merged"

        {:ok, context}
      end

      then_ "main still holds the first agent's work", context do
        assert read(context.running_root, "lib/broken_oaths/diplomacy/war.ex") =~ ":first"
        {:ok, context}
      end
    end
  end
end
