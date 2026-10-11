defmodule CodeMySpecSpex.Story1046.Criterion3169Spex do
  @moduledoc """
  Story 1046 — Historical findings recorded on main do not veto a clean gate.

  The running copy has older findings from unrelated work. The merged tree is
  measured afresh on the queue's gate and is clean; that certification permits
  landing even though main's separately recorded findings still exist.
  A red merged-tree gate remains a refusal.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Historical main findings do not override a clean merged-tree gate", criterion: 1176 do
    scenario "the running copy already carries another epic's problems" do
      given_ "a story branch with committed work", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        story = a_promotable_story(context, qa: :not_passed)

        :ok =
          StoryIssueBag.certify(
            context.scope,
            story.id,
            head_of(context, context.agent_root)
          )

        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)
        {:ok, Map.put(context, :story, story)}
      end

      given_ "the running copy already carries two problems of its own", context do
        there = %{context.scope | active_working_copy_id: context.running.working_copy_id}

        for path <- [
              "lib/broken_oaths/other_epic/settler.ex",
              "lib/broken_oaths/other_epic/terrain.ex"
            ] do
          Fixtures.record_problem(there, "credo", %{
            file_path: path,
            message: "somebody else's finding",
            severity: :error
          })
        end

        {:ok, context}
      end

      given_ "main has independent work and both copies' analyzers are current", context do
        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        response = promote(context, context.story.number)
        refute response.isError, response_text(response)
        the_gate_answers(context)
        told = what_the_agent_was_told(context)
        assert told =~ "landed on main", told
        {:ok, context |> Map.put(:response, response) |> Map.put(:told, told)}
      end

      then_ "the promotion completes", context do
        assert context.told =~ "landed on main",
               "the fresh gate was clean but historical main findings blocked landing: #{context.told}"

        {:ok, context}
      end

      then_ "and the work is on the running copy", context do
        merged = read(context.running_root, "lib/broken_oaths/diplomacy/war.ex")

        assert merged =~ ":from_the_copy"

        {:ok, context}
      end
    end
  end
end
