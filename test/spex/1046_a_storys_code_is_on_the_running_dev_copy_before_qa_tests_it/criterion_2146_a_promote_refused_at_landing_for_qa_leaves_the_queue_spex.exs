defmodule CodeMySpecSpex.Story1046.Criterion2146Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 2146 — A promote refused at landing for QA leaves the queue, and
  the candidate behind it lands.

  Only the story's team can supply the QA it lacks, so retrying it changes
  nothing. Re-queued, story 1091 went back to the head of the queue and was
  refused again every cycle, holding every candidate behind it (2026-10-11).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.PromotionHelpers

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story whose QA lapses while it waits is taken out of the queue", criterion: 2146 do
    scenario "a blocking issue is accepted on the story after it was queued" do
      given_ "a QA'd story queued for promotion, and another copy's finished work", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        story = a_promotable_story(context)
        context = analyzers_are_current(context)

        # Main moves past the story, so its batch is built and gated in the
        # gate copy, where landing checks its QA.
        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        context = another_candidate(context, :other)

        commit_work(
          context,
          context.other.root,
          "lib/broken_oaths/diplomacy/peace.ex",
          "defmodule BrokenOaths.Diplomacy.Peace do\nend\n"
        )

        context = its_analyzers_are_current(context, context.other)

        queued = promote(context, story.number)
        refute queued.isError, response_text(queued)

        {:ok, Map.put(context, :story, story)}
      end

      when_ "a blocking issue is accepted on the story before it lands", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        created =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "The war is declared twice",
              severity: "high",
              description: "Declaring war on an empire already at war declares it again.",
              story_number: context.story.number
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        [_, issue_id] = Regex.run(~r/\(ID: ([0-9a-f-]{36})\)/, response_text(created))

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: issue_id, category: "bug"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, accepted), response_text(accepted)

        the_gate_answers(context)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the story's team is told it was taken out and needs QA", context do
        assert context.told =~ "was taken out of the queue", context.told
        assert context.told =~ "needs QA", context.told
        {:ok, context}
      end

      then_ "the candidate behind it lands", context do
        response = promote_from(context.other, nil)
        refute response.isError, response_text(response)
        told = what_was_told(context.other.agent_id)

        # Re-queued, the refused story would be older than this and gated
        # first, refused again, and this would never land.
        assert told =~ "landed on main", told
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex")
        {:ok, context}
      end
    end
  end
end
