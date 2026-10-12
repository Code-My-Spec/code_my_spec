defmodule CodeMySpecSpex.Story1046.Criterion2020Spex do
  @moduledoc """
  Story 1046 — Promotion lands verified work on the running dev copy.
  Criterion 2020 — The queue never discards a copy's uncommitted work: a
  batch is gated and landed without resetting or cleaning the promoting
  copy's working tree, whether it is queued alone or behind others. If the
  queue cannot proceed without a clean tree it refuses the batch and says
  so, rather than making the tree clean.

  Rule: `promote` checks the promoting copy's own tree once, at the moment
  it is called (criterion 1181). Once queued, the batch is gated on a
  separate gate checkout and landed by merging the candidate's own commit
  into the running checkout — neither touches the promoting agent's copy
  again. Work the agent leaves uncommitted there afterward, while its
  candidate still waits for the gate, survives the landing untouched.
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

  spex "A promoting copy's own uncommitted work survives its candidate's landing",
       criterion: 2020 do
    scenario "the agent keeps working on its copy while its candidate waits for the gate" do
      given_ "a story branch main has moved past, queued for promotion", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        context = Map.put(context, :story, a_promotable_story(context))
        context = analyzers_are_current(context)

        queued = promote(context, context.story.number)
        refute queued.isError, response_text(queued)

        # The agent keeps working on its own copy while the candidate waits
        # for the gate — legitimate, per criterion 2021.
        write(context.agent_root, "lib/broken_oaths/diplomacy/notes.ex", notes())
        {status, 0} = git(context, context.agent_root, ["status", "--porcelain"])

        assert status =~ "notes.ex",
               "the premise failed: the agent's copy is not dirty, so this " <>
                 "would pass against a tool that never looks"

        {:ok, Map.put(context, :status_before, status)}
      end

      when_ "the gate answers and the candidate lands", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the candidate lands, and the promoting copy's own uncommitted work is untouched",
            context do
        assert context.told =~ "landed on main", context.told

        {status, 0} = git(context, context.agent_root, ["status", "--porcelain"])

        assert status == context.status_before,
               "the promoting copy's own tree changed during the landing: #{status}"

        assert exists?(context.agent_root, "lib/broken_oaths/diplomacy/notes.ex"),
               "the promoting copy's own uncommitted work was discarded"

        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"

  defp notes, do: "# scratch notes, never committed\n"
end
