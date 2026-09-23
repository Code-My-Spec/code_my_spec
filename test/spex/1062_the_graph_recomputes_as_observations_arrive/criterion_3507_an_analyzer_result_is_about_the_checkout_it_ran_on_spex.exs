defmodule CodeMySpecSpex.Story1062.Criterion3507Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3507 — An analyzer result is about the checkout it ran on.

  Rule: a run answers for the tree it read, and for no other.

  ## Why an analyzer is the sharp case

  A verdict is a statement about one checkout — [[criterion 3497]] establishes
  that much from files. An analyzer result is the same claim with a worse
  failure mode, because the thing it reports is *absence*: credo finding nothing
  means "nothing wrong in the tree I read", and fanning that out settles every
  other checkout to "nothing wrong" in trees the run never opened.

  That is the direction the mistake goes. A run on a clean worktree does not
  make another worktree clean, and a graph that says otherwise hands a coding
  agent a component whose findings have been silently answered away somewhere
  else.

  ## What it observes, and why not the other checkout's rows

  The **checkout recorded on the observation**, read off the dev page's backlog.

  Not the *entity* scope, which is a different narrowing and reads `unknown` for
  a perfectly well-routed analyzer mark: a run reports about a tree, not about a
  list of components, so it names its checkout and no entities. Conflating the
  two is how this criterion was misdiagnosed for most of a session — the entity
  scope said `unknown` while the checkout said exactly the right thing.

  The obvious instrument — read the other checkout's rows and show they did not
  move — cannot be used here, and finding that out took a while. `cached_graph/1`
  settles before answering and `GraphWatcher.settle/2` remembers the vantage the
  reader named, so asking what a checkout holds *queues a computation for it*
  which the next pass then legitimately performs. The question causes the
  answer. A `settle=false` read was added for exactly this
  (`GraphReadHelpers.peek_graph/2`) and still leaves earlier reads' requests
  outstanding, so the checkout gets recomputed for a reason that has nothing to
  do with the analyzer.

  What the rows would have shown, the mark already says: `entity_scope` and the
  checkout it was recorded from are what `ShadowProjector` and `GraphWatcher`
  both route on. An analyzer observation scoped to its own checkout cannot
  settle another, and one recorded project-wide inevitably does — so the scope
  *is* the claim, and it is observable without disturbing anything.

  [[Criterion 3518]] holds the other end of the same rule from the drain's side:
  the number of checkouts a pass settles is the number its observations named.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @endpoint CodeMySpecWeb.Endpoint
  @moduletag timeout: 60_000

  spex "An analyzer settles the checkout it ran on" do
    scenario "a run completes on one of two checkouts" do
      given_ :synced_context_component

      given_ "a second checkout of the same project", context do
        {:ok, second_root} = Briefly.create(directory: true)
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:first_id, context.scope.active_working_copy_id)
         |> Map.put(:second_id, second_id)}
      end

      given_ "both checkouts' requirements stored and the queue drained", context do
        assert read_settled_graph(context, context.first_id)["nodes"] != [],
               "the first checkout stores no requirements, so there is nothing to settle"

        assert read_settled_graph(context, context.second_id)["nodes"] != [],
               "the second checkout stores no requirements, so this is a one-checkout project"

        # Once per checkout: a read queues work for the vantage it named, and a
        # pass pays only what it was asked for.
        :ok = Fixtures.settle_graph(%{context.scope | active_working_copy_id: context.first_id})
        :ok = Fixtures.settle_graph(%{context.scope | active_working_copy_id: context.second_id})

        {:ok, context}
      end

      when_ "it completes on the first checkout and records a finding", context do
        # Stopped first, so the marks are still there to read. The watcher is
        # eager and an observation made while it is up is drained before
        # anything can look at its scope — the same reason
        # [[criterion 3512]] and [[criterion 3513]] stop it.
        Fixtures.stop_graph_watchers()

        scope = %{context.scope | active_working_copy_id: context.first_id}
        run = Fixtures.start_analysis_run(scope, "credo")
        :ok = Fixtures.complete_analysis_run(scope, run)

        # A finding, because a clean run legitimately settles nothing —
        # [[criterion 3448]] is the rule that says so.
        :ok =
          Fixtures.replace_problems(scope, context.component.id, "credo", [
            %{
              message: "Function body is nested too deep (max_nesting is 2).",
              file_path: "lib/reservations/booking.ex",
              line: 14
            }
          ])

        {:ok, Map.put(context, :marks, analyzer_marks(context))}
      end

      then_ "the run left an observation behind", context do
        assert context.marks != [],
               """
               The analyzer completed and recorded findings and nothing was
               queued.

               A run that announces nothing is the silent-writer defect this
               whole story exists to remove: the graph goes on serving answers
               computed before the analyzer looked, and nothing says so.
               """

        {:ok, context}
      end

      then_ "and every one of them names the checkout it ran on", context do
        elsewhere = Enum.reject(context.marks, &(&1 == context.first_id))

        assert elsewhere == [],
               """
               The analyzer ran on the first checkout and its observations name
               #{inspect(Enum.map(elsewhere, &short/1))}.

               `project-wide` is the failure that matters here. A mark that
               names no checkout is read by every checkout, so the run's
               findings settle trees it never opened — and what a run mostly
               reports is *absence*, so fanning it out answers "nothing wrong"
               for a component with real findings somewhere else.

               first checkout:  #{short(context.first_id)}
               second checkout: #{short(context.second_id)}
               named:           #{inspect(Enum.map(context.marks, &short/1))}
               """

        {:ok, context}
      end
    end
  end

  # Which checkout each of the analyzer's queued observations names, off the
  # dev page's backlog.
  #
  # Filtered to the two writers this scenario drove — the run landing and the
  # findings it recorded. The backlog holds the whole project's queue, including
  # whatever the fixtures announced while building the second checkout, and
  # those are not what this criterion is about.
  defp analyzer_marks(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    ~r/data-test="backlog-row"[^>]*?data-source="([^"]*)"[^>]*?data-copy="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.filter(fn [_m, source, _copy] -> source in ["Analysis", "Problems"] end)
    |> Enum.map(fn [_m, _source, copy] -> copy end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp short("project-wide"), do: "project-wide"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
end
