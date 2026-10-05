defmodule CodeMySpecSpex.Story1046.Criterion1964Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1964 — Promotion answers in seconds with its place in the queue.

  Rule: `promote` queues the copy's HEAD and answers at once; the queue gates
  and lands it later.

  Not a stopwatch, for the reason 1372 gave: on a loaded box a wall-clock bound
  tests the machine. The contract instead — the reply names its place in the
  queue and says nothing is merged yet, and it arrives while the gate has not
  yet been answered by a single analyzer, which a reply that waited could not.
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

  spex "Promotion answers in seconds with its place in the queue", criterion: 1964 do
    scenario "an agent promotes work main has moved past" do
      given_ "a story branch with work on it", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "main has moved on since the branch left it", context do
        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "it is told its place in the queue, and that nothing is merged yet", context do
        text = response_text(context.response)
        refute context.response.isError, "the promotion was refused: #{text}"

        assert text =~ "position 1",
               "the reply does not say where it is in the queue. Got: #{text}"

        assert text =~ "Nothing is merged yet",
               "the reply claims more than happened. Got: #{text}"

        {:ok, context}
      end

      then_ "the answer came before any analyzer had answered the gate", context do
        assert the_gate_is_running(context) == ~w(compiler credo exunit spex)

        refute exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex"),
               "the work is on the running checkout before the gate was answered"

        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
