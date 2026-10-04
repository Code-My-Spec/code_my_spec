defmodule CodeMySpecSpex.Story1046.Criterion3168Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3168 — A merge that breaks the target is not a completed promotion.

  Rule: a promotion that merges must not leave the target carrying problems
  it did not carry before — checked by gating the merged tree, because two
  branches can each be clean and merge without conflict into a tree that does
  not compile, and no gate run before the merge can see that.

  Reachable again under the promotion queue (2026-10-04). Between 54aa534c and
  the queue, `--ff-only` refused any divergence before a merge, so this
  scenario could only assert a "behind main" refusal. The queue merges the
  candidate onto main in its own gate checkout and runs every analyzer there,
  at the merged commit, before anything lands — which is this rule as first
  written. The gate copy's harness is played by the scenario: it reports what
  its compiler finds in the merged tree.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()

    # The joins go through a real channel, which runs in a process of its own,
    # and the queue gates and lands from its own worker.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A merge that breaks the target is not a completed promotion", criterion: 1175 do
    scenario "main renamed a module the story branch still calls by its old name" do
      given_ "a story branch whose new module imports War", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        write(context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", """
        defmodule BrokenOaths.Diplomacy.Peace do
          import BrokenOaths.Diplomacy.War
          def sue, do: declare()
        end
        """)

        {_, 0} = git(context, context.agent_root, ["add", "-A"])
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-m", "peace imports war"])

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "main has since renamed that module", context do
        write(context.running_root, "lib/broken_oaths/diplomacy/war.ex", """
        defmodule BrokenOaths.Diplomacy.Warfare do
          def declare, do: :base
        end
        """)

        {_, 0} =
          git(context, context.running_root, ["commit", "-q", "-am", "rename War to Warfare"])

        {:ok, context}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      when_ "the compiler finds the merged tree broken, and again when it is re-run", context do
        broken = %{
          "compiler" => [
            %{
              "file" => "lib/broken_oaths/diplomacy/peace.ex",
              "line" => 2,
              "severity" => "error",
              "message" => "module BrokenOaths.Diplomacy.War is not loaded and could not be found"
            }
          ]
        }

        context
        |> the_gate_answers(broken)
        |> the_gate_answers(broken, sources: ["compiler"])

        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the agent is told its work was taken out, and what broke", context do
        assert context.told =~ "taken out",
               "a merge that broke the tree was not reported as refused. Got: #{context.told}"

        assert context.told =~ "lib/broken_oaths/diplomacy/peace.ex",
               "the refusal has to name what the merged tree broke. Got: #{context.told}"

        {:ok, context}
      end

      then_ "and the application was not restarted", context do
        refute exists?(context.running_root, ".restarted"),
               "nothing landed, so nothing should have been restarted either"

        {:ok, context}
      end

      then_ "and the running checkout never held the broken merge", context do
        assert read(context.running_root, "lib/broken_oaths/diplomacy/war.ex") =~ "Warfare",
               "the running checkout should still have main's rename"

        refute exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex"),
               "the story's file crossed into the running checkout despite the merge breaking it"

        {:ok, context}
      end
    end
  end
end
