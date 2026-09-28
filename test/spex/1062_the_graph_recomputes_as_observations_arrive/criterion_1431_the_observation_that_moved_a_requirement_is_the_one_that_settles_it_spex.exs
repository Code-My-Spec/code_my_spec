defmodule CodeMySpecSpex.Story1062.Criterion3523Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3523 — The observation that moved a requirement is the one that
  settles it.

  Rule: a requirement is correct by the time the observation that moved it is
  discarded.

  ## Why this is stated as a timing rule

  [[Criterion 3493]] says an observation settles every requirement it moves.
  This says *when*: before the mark is consumed, and without waiting for
  anything else to happen.

  The two are separable, and the gap between them is where the failure lives. A
  projection that settles most of what an observation moved, and leaves the rest
  to be picked up by whatever names those entities next, is correct on a busy
  project and wrong on a quiet one. Every test passes, because a test does
  something next. The symptom only appears when nothing does — which is the
  state a real project is in most of the time.

  [[Criterion 3522]] is the same fact from the other side: nothing sweeps, so an
  answer nobody is coming back for stays wrong. That is what makes this timing
  rule load-bearing rather than a preference about promptness.

  ## The observation

  An issue filed at the gating severity, which moves `issues_triaged` to false.
  There is nothing to ask — an untriaged issue *is* that verdict — so a handler
  can write it directly, and a system that gets this wrong is one that consumed
  the mark having settled something else.

  Read immediately after the drain and before anything else touches the project.
  A second observation, a sync, even a read that recomputes would all mask it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "A requirement is correct before its observation is discarded", criterion: 1431 do
    scenario "an issue is filed and nothing else happens" do
      given_ :synced_context_component

      given_ "a settled graph reporting nothing untriaged", context do
        story =
          create_story(context.scope,
            title: "The story the issue is about",
            description: "so the observation names something"
          )

        :ok = Fixtures.settle_graph(context.scope)
        before = read_settled_graph(context)

        assert satisfaction_of(before, "issues_triaged") == true,
               """
               The project already reports an untriaged queue before anything
               was filed, so the change this criterion is about cannot be
               observed.

               issues_triaged: #{inspect(satisfaction_of(before, "issues_triaged"))}
               """

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      when_ "an observation that moves a requirement is applied", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "filed at the severity the graph gates on",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :after, read_graph(context))}
      end

      then_ "that requirement is correct once the observation has been applied", context do
        assert satisfaction_of(context.after, "issues_triaged") == false,
               """
               An issue was filed and the drain that consumed the observation
               left `issues_triaged` still reporting nothing untriaged.

               An untriaged issue at the gating severity *is* that verdict —
               there is nothing to ask. A projection that consumed the mark
               without writing it has discarded the only record that this
               requirement needed answering.

               issues_triaged: #{inspect(satisfaction_of(context.after, "issues_triaged"))}
               """

        {:ok, context}
      end

      then_ "and correcting it did not depend on a later observation", context do
        # Read again with nothing having happened in between. If the answer only
        # became right on this second read, it was a read that recomputed rather
        # than an observation that settled — and on a quiet project, where
        # nothing reads for hours, the graph would have been wrong for all of
        # that time.
        again = read_graph(context)

        assert satisfaction_of(again, "issues_triaged") ==
                 satisfaction_of(context.after, "issues_triaged"),
               """
               The answer changed between two reads with no observation in
               between.

               first read:  #{inspect(satisfaction_of(context.after, "issues_triaged"))}
               second read: #{inspect(satisfaction_of(again, "issues_triaged"))}

               That means the correction came from the read rather than from
               the observation. Reads do not compute any more, which is the
               whole premise the cost rules are built on — and a project nobody
               is reading would have served the stale answer indefinitely.
               """

        {:ok, context}
      end
    end
  end
end
