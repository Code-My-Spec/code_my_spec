defmodule CodeMySpecSpex.Story1062.Criterion3498Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3498 — A reader with no checkout is not served a checkout's answers.

  Rule: a verdict belongs to one checkout, and an observation says which
  checkouts it moves.

  ## Two facts, and this is the reader where they differ

  A verdict is a statement about a checkout, so every answer has a row-space it
  came from and a tree it is about. For an agent those are the same thing: it
  names its checkout and gets that checkout's rows, computed from that
  checkout's files.

  A reader that names none is the case where they come apart. Its answers live
  under no working copy — the row-space every such reader shares — and they are
  computed from the project's main checkout, because "this component has an
  implementation" is only ever true from somewhere.

  ## What goes wrong when that is collapsed

  Both halves have failed, in opposite directions:

    * Answered from *every* checkout at once, a file present in one worktree and
      absent in another reads as present. Measured: twenty components read as
      having an implementation that exists only in another tree, and a component
      whose single file was one worktree's spec was reported project-wide as an
      orphan every agent was told to resolve and none could.
    * Answered into a *checkout's* rows, a graph that is not that checkout's
      answer ends up stored as though it were.

  ## Why this asserts on the response rather than on a verdict

  3501 next door asserts the verdicts: main's files move these answers and no
  other checkout's does. This asserts the thing that made those verdicts
  possible to reason about at all — that the graph says which rows answered and
  whose tree they are about, rather than carrying answers and nothing about what
  they are answers *to*. A graph that is right by luck and cannot say so is one
  nobody can check.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.MainAgentHelpers, only: [designate_main_copy: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The project's own answers say which checkout they are about", criterion: 1413 do
    scenario "A reader with no checkout is not served a checkout's answers" do
      given_ :synced_context_component

      given_ "a checkout that is the project's main one", context do
        {:ok, root} = Briefly.create(directory: true)
        {reply, _socket} = join_working_copy_socket(context, root, "the main checkout")
        main_id = reply["harness_id"] || reply[:working_copy_id]

        :ok = designate_main_copy(context, main_id)

        {:ok, Map.put(context, :main_id, main_id)}
      end

      given_ "and another checkout, which speaks for nothing but itself", context do
        {:ok, root} = Briefly.create(directory: true)
        {reply, _socket} = join_working_copy_socket(context, root, "the other checkout")
        other_id = reply["harness_id"] || reply[:working_copy_id]

        refute other_id == context.main_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok, Map.put(context, :other_id, other_id)}
      end

      when_ "a reader that names no checkout asks for the graph", context do
        {:ok, Map.put(context, :graph, read_settled_graph(context))}
      end

      then_ "it is answered from the rows kept for no checkout in particular", context do
        rows = get_in(context.graph, ["vantage", "rows"])

        assert is_nil(rows),
               """
               A reader that named no checkout was answered from a checkout's
               own rows.

               Those rows are that copy's answer. Serving them here stores and
               serves one checkout's view as the project's, and the reader has
               no way to know which copy it is looking at — every reader that is
               not an agent resolves to this vantage, the browser included.

               answered from rows: #{inspect(rows)}
               main: #{inspect(context.main_id)}, the other: #{inspect(context.other_id)}
               """

        {:ok, context}
      end

      then_ "and it says whose tree those answers are about", context do
        files = get_in(context.graph, ["vantage", "files"])

        assert files == context.main_id,
               """
               The project's answers are not computed from the project's main
               checkout.

               They have to be computed from some tree — a verdict is a
               statement about a checkout — and main is the one the project has
               nominated. Any other answer is either a blend, where a file in one
               worktree reads as present everywhere, or somebody else's tree
               speaking for the project.

               computed from: #{inspect(files)}
               main: #{inspect(context.main_id)}, the other: #{inspect(context.other_id)}
               """

        {:ok, context}
      end
    end
  end
end
