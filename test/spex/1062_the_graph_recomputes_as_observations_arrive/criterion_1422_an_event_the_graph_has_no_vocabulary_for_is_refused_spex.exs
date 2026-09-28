defmodule CodeMySpecSpex.Story1062.Criterion3513Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3513 — An event the graph has no vocabulary for is refused.

  Rule: a kind that is not declared cannot reach the queue.

  ## Why refusal rather than a default

  The cheap alternative is to accept any kind and let it fall through to
  recomputing the entities it names. That is always *correct* — an unhandled
  event is strictly more information than a bare mark — which is exactly why it
  would never be noticed. An undeclared kind would cost a full recompute on
  every occurrence and report itself as an ordinary drain the whole time.

  The closed list is the forcing function. Because adding a way to move the
  graph means editing `kinds/0`, the set is finite and known, and
  [[criterion 3514]] can then ask of every entry whether anything applies it. A
  new kind is therefore either applied or written down as falling back, and it
  cannot be neither. Accepting undeclared kinds is what would make that question
  unanswerable, because the set to ask it about would not exist.

  ## How this became observable

  The refusal used to be demonstrable only by emitting an undeclared kind and
  catching the raise — which meant the only way to confirm the guard was to
  attempt the thing the guard exists to prevent, from a module the spec boundary
  does not permit reaching.

  `GraphInputs.check/2` is that same refusal, factored out and asked rather than
  triggered. `event/6` calls it and raises on the error, so this is the live
  rule and not a second copy of it, and the dev page publishes its answer.

  Two things are asserted together, because either alone can be satisfied
  wrongly: that the guard refuses an undeclared kind, and that the vocabulary is
  closed *in practice* — every kind reaching the queue is one the page publishes
  as declared. A guard that refuses while something else writes marks behind it
  would pass the first and fail the second.
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

  spex "Only declared kinds reach the queue", criterion: 1422 do
    scenario "several writers move the graph while nothing is draining" do
      given_ :synced_context_component

      given_ "a settled graph", context do
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      when_ "writers of several kinds announce", context do
        # Stopped first so the marks accumulate instead of being drained on
        # arrival — the queue is what carries the kind, and an applied mark is
        # gone before anything can read it.
        Fixtures.stop_graph_watchers()

        story =
          create_story(context.scope,
            title: "A story arriving",
            description: "story_created"
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "an issue arriving",
              description: "issue_created",
              severity: "medium",
              story_number: story.number
            },
            frame
          )

        refute filed.isError, inspect(filed)

        {:ok, Map.put(context, :page, page(context))}
      end

      then_ "the queue carries kinds", context do
        assert context.page.queued_kinds != [],
               """
               Nothing reached the queue, so this scenario cannot tell a closed
               vocabulary from an empty one.

               Two writers announced — a story and an issue — with nothing
               running to drain them. An empty queue means either the writers
               are silent, or something applied the marks that this scenario
               did not account for.
               """

        {:ok, context}
      end

      then_ "and every kind that reached it was declared", context do
        undeclared = context.page.queued_kinds -- context.page.declared_kinds

        assert undeclared == [],
               """
               #{inspect(undeclared)} reached the queue without being declared.

               An undeclared kind is a mark nothing knows how to apply. It costs
               a full recompute every time it occurs and reports itself as an
               ordinary incremental drain while doing so — the one failure shape
               that cannot be found by reading the numbers, because every number
               looks normal.

               declared: #{inspect(context.page.declared_kinds)}
               queued:   #{inspect(context.page.queued_kinds)}
               """

        {:ok, context}
      end

      then_ "and declaring a kind is what puts it on the published list", context do
        assert context.page.declared_kinds != [],
               """
               The page publishes no vocabulary, so "declared" is not a thing
               anybody can check against and the closure asserted above is
               vacuous.
               """

        {:ok, context}
      end

      then_ "and the guard itself refuses an undeclared kind", context do
        g = guarantee(context, "no vocabulary for")

        assert g.found?,
               "the page publishes no guarantee about undeclared kinds, so the " <>
                 "refusal is unobservable again"

        assert g.refused?,
               """
               The writer API accepted a kind nobody declared.

               An undeclared kind becomes a mark nothing knows how to apply. It
               costs a full recompute every time it occurs and reports itself as
               an ordinary incremental drain while doing so — the one failure
               shape that cannot be found by reading the numbers.

               #{g.body}
               """

        {:ok, context}
      end
    end
  end

  # What the dev page publishes: the declared vocabulary, and the kinds actually
  # sitting in this project's queue.
  defp page(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    %{
      declared_kinds: scan(html, ~r/data-test="vocabulary-kind"\s+data-kind="([^"]+)"/),
      queued_kinds:
        html
        |> scan(~r/data-test="backlog-row".*?<td class="opacity-60">([a-z_]+)<\/td>/s)
        |> Enum.reject(&(&1 == "invalidate"))
    }
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

  defp scan(html, regex) do
    regex
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
