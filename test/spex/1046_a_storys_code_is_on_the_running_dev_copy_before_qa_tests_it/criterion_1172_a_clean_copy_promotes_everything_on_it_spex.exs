defmodule CodeMySpecSpex.Story1046.Criterion3165Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3165 — A clean copy promotes everything on it.

  Rule: A working copy carrying any problem promotes nothing.

  The same rule read the other way. The unit is the copy, not the story: three
  stories finished on one checkout reach the running copy together, in one
  merge, because a branch cannot carry one story's commits and not another's.

  Three rather than one, so that "everything on it" is actually exercised. A
  promotion that moved only the story the agent happened to be holding would
  pass a one-story version of this spec and still be wrong. Asserted against
  the running checkout's own files rather than against the response text —
  what matters is that the work is *there*.
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
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "A clean copy promotes everything on it", criterion: 1172 do
    scenario "three finished stories reach the running copy in one merge" do
      given_ "three stories finished on the coding agent's copy", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        # A module name per file, not one name three times.
        #
        # These three all defined `BrokenOaths.Diplomacy.X`, which made the
        # running checkout uncompilable — the restart recipe builds
        # `diplomacy/*.ex` in one pass and duplicate definitions are a compile
        # error. That was survivable while the restart was synchronous and this
        # scenario never looked at it. It stopped being survivable when the
        # restart became detached (54aa534c): the compile error now lands after
        # this test has finished, and a logged error fails whichever test is
        # running when it arrives — which is how criterion 3167 started failing
        # in-suite while passing alone, for a fixture defect in this file.
        for {file, mod, body} <- [
              {"war.ex", "War", ":declared"},
              {"peace.ex", "Peace", ":sued"},
              {"oath.ex", "Oath", ":broken"}
            ] do
          write(
            context.agent_root,
            "lib/broken_oaths/diplomacy/#{file}",
            "defmodule BrokenOaths.Diplomacy.#{mod} do\n  def act, do: #{body}\nend\n"
          )
        end

        {_, 0} = git(context, context.agent_root, ["add", "-A"])
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-m", "three stories"])

        story = a_promotable_story(context, qa: :not_passed)
        :ok = StoryIssueBag.certify(context.scope, story.id, head_of(context, context.agent_root))
        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)
        {:ok, Map.put(context, :story, story)}
      end

      given_ "the copy carries no problems", context do
        # given: already true — nothing recorded any. `record_problem/3` is the
        # only thing that puts a problem on a copy in a spec, and neither this
        # scenario nor `a_promotable_project/1` calls it.
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
        outcome = what_the_agent_was_told(context)
        assert outcome =~ "landed on main", outcome
        {:ok, Map.put(context, :outcome, outcome)}
      end

      then_ "all three stories' work is on the running copy", context do
        for {file, body} <- [
              {"war.ex", ":declared"},
              {"peace.ex", ":sued"},
              {"oath.ex", ":broken"}
            ] do
          path = "lib/broken_oaths/diplomacy/#{file}"

          assert exists?(context.running_root, path),
                 "#{file} was left behind by a promotion that reported: " <>
                   context.outcome

          assert read(context.running_root, path) =~ body
        end

        {:ok, context}
      end
    end
  end
end
