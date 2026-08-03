defmodule CodeMySpecSpex.Story562.Criterion5646Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5646 — A parent context's `implementation_file` has no
  direct incoming edge from a child's `implementation_file` when
  that child also has a `tests_passing` node. The longer path
  child.implementation_file → child.tests_passing → parent.implementation_file
  exists, so transitive reduction prunes the direct shortcut.

  The parent context's implementation work is correctly gated on
  the child's full chain finishing (impl + tests), not on the
  child's impl alone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Direct child.impl_file → parent.impl_file edge is pruned through child.tests_passing" do
    scenario "parent's impl_file is fed by child.tests_passing, not child.implementation_file" do
      given_ :context_with_three_children

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the repository child has no direct impl→impl edge into the parent context",
            context do
        # Repository uses default_graph which has both implementation_file
        # and tests_passing — the structural prerequisite for transitive
        # reduction to apply.
        parent_impl_key =
          GraphAssertions.node_key(
            "component",
            context.parent_context.id,
            "implementation_file"
          )

        repo_impl_key =
          GraphAssertions.node_key(
            "component",
            context.child_repository.id,
            "implementation_file"
          )

        shortcut =
          context.graph
          |> GraphAssertions.edges_to(parent_impl_key)
          |> Enum.filter(fn e -> e["source"] == repo_impl_key end)

        assert shortcut == [],
               "expected the direct repository.impl_file → parent.impl_file shortcut to be pruned, found: #{inspect(Enum.map(shortcut, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end

      and_ "the repository's tests_passing feeds the parent's impl_file",
           context do
        parent_impl_key =
          GraphAssertions.node_key(
            "component",
            context.parent_context.id,
            "implementation_file"
          )

        repo_tests_key =
          GraphAssertions.node_key(
            "component",
            context.child_repository.id,
            "tests_passing"
          )

        edge =
          context.graph
          |> GraphAssertions.edges_to(parent_impl_key)
          |> Enum.find(fn e -> e["source"] == repo_tests_key end)

        assert edge,
               "expected an incoming edge from repository.tests_passing to parent.implementation_file"

        {:ok, context}
      end
    end
  end
end
