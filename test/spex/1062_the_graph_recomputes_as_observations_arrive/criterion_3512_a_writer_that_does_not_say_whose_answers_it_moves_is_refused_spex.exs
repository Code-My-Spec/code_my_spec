defmodule CodeMySpecSpex.Story1062.Criterion3512Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3512 — A writer that does not say whose answers it moves is
  refused.

  Rule: vantage is declared by the writer, never inherited and never defaulted
  silently.

  ## Why it cannot be taken from the ambient scope

  A verdict is a statement about one checkout, so an observation has to say
  whose answers it moves or the projector cannot route it. The tempting
  shortcut is to read it off the scope the writer already has — and that is
  wrong in a way nothing would catch.

  An agent renaming a story has an active checkout on its scope, and the rename
  is not about that checkout. Inheriting would narrow it to the agent's own
  worktree and leave every other one carrying the old title, silently, for as
  long as nothing else happened to name those stories. The writer is the only
  thing that knows which of the two it is, so the writer is made to say.

  `:project_wide` is the conservative direction and the one an unsure writer
  must take: fanning out too far costs work, narrowing too far costs
  correctness. [[Criterion 3508]] is that half; [[criterion 3518]] bounds the
  other.

  ## How this became observable

  The refusal used to be a bare guard clause, demonstrable only by making a call
  that failed — so the guarantee existed and nothing could show it.
  `GraphInputs.check/2` is the same refusal asked rather than triggered:
  `event/6` calls it and raises on the error, so the page publishes the live
  rule and not a description of it.

  Both halves are asserted, because the guard and its effect can each be right
  while the other is wrong. The guard must refuse a writer that says nothing;
  and every mark actually in the queue must carry a scope, because a writer that
  got through without saying would leave one naming neither a checkout nor the
  project and the projector would have to guess.

  `unknown` is not that failure. It is a writer saying it could not tell which
  *entities* moved — recorded, visible, and read as the whole project. The
  failure is a mark that says nothing at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @endpoint CodeMySpecWeb.Endpoint
  @moduletag timeout: 60_000

  # The three answers a mark can carry. `unknown` is a writer that moved the
  # graph and could not say which entities — a real claim, recorded rather than
  # hidden, and the expensive one. What must never appear is a fourth value, or
  # a blank.
  @scopes ~w(entity project unknown)

  spex "Every mark says whose answers it moves" do
    scenario "writers of both vantages announce while nothing is draining" do
      given_ :synced_context_component

      given_ "a settled graph", context do
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      when_ "writers announce", context do
        # Stopped first so the marks accumulate: an applied mark is gone before
        # its scope can be read.
        Fixtures.stop_graph_watchers()

        story =
          create_story(context.scope,
            title: "A story arriving",
            description: "a writer whose change every checkout reads"
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "an issue arriving",
              description: "another writer whose change is about no checkout",
              severity: "medium",
              story_id: story.id
            },
            frame
          )

        refute filed.isError, inspect(filed)

        {:ok, Map.put(context, :scopes, queued_scopes(context))}
      end

      then_ "marks reached the queue", context do
        assert context.scopes != [],
               """
               Nothing reached the queue, so this scenario cannot tell a mark
               that declared its vantage from one that was never written.
               """

        {:ok, context}
      end

      then_ "and every one of them says whose answers it moves", context do
        unexplained = Enum.reject(context.scopes, &(&1 in @scopes))

        assert unexplained == [],
               """
               #{inspect(unexplained)} — mark(s) in the queue carry a scope that
               is none of #{inspect(@scopes)}.

               A mark that names neither a checkout nor the project leaves the
               projector to guess, and the guess it would have to make is the
               one that cannot be made safely: narrowing a project-wide change
               leaves every other checkout stale and silent about it.

               `unknown` is not that failure. It is a writer saying it could not
               tell which entities moved — recorded, visible, and read as the
               whole project. The failure is a mark that says nothing at all.

               scopes queued: #{inspect(context.scopes)}
               """

        {:ok, context}
      end

      then_ "and the guard itself refuses a writer that says nothing", context do
        g = guarantee(context, "whose answers it moves")

        assert g.found?,
               "the page publishes no guarantee about vantage, so the refusal is " <>
                 "unobservable again"

        assert g.refused?,
               """
               The writer API accepted an announcement that did not say whose
               answers it moves.

               A default here is the dangerous kind. Inheriting the vantage from
               the ambient scope narrows a story rename to the renaming agent's
               own worktree and leaves every other checkout carrying the old
               title — silently, for as long as nothing else names those stories.

               #{g.body}
               """

        {:ok, context}
      end
    end
  end

  # One published guarantee, by the claim it makes.
  defp guarantee(context, needle) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    ~r/data-test="guarantee" data-refused="([^"]*)"(.*?)<\/li>/s
    |> Regex.scan(html)
    |> Enum.find(fn [_m, _refused, body] -> body =~ needle end)
    |> then(fn
      [_m, refused, body] -> %{found?: true, refused?: refused == "true", body: body}
      nil -> %{found?: false, refused?: false, body: ""}
    end)
  end

  # The scope column of every backlog row the page publishes for this project.
  defp queued_scopes(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    ~r/data-test="backlog-row"[^>]*?data-scope="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
