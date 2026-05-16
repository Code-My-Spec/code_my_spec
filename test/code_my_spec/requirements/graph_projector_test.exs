defmodule CodeMySpec.Requirements.GraphProjectorTest do
  @moduledoc """
  Structural unit tests for the graph projector.

  These pin the projector's *contract* — what every output graph
  must satisfy regardless of which requirement names exist. They
  intentionally avoid asserting "node `spec_valid` is at row 2" or
  any other domain-named position; that kind of meaning lives in
  BDD specs (`test/spex/671_*`, `562_*`, `561_*`).

  We assert:
    * structural integrity (no dangling edges, no duplicate keys,
      finite coordinates)
    * topological flow (intra-entity edges flow downward; fan-in
      sits below all sources)
    * spatial clustering (nodes for the same entity sit on the
      same x-column)
    * determinism (same input → same output)

  The projector takes a `Scope` for its public API, but every
  property below depends only on the `{nodes, edges}` it computes
  from that scope. Tests here use the same fixture as
  `Story562`/`Story671` (`:context_with_three_children` via the
  /sync LiveView), so a regression here will also fail those
  spex — but the unit-test phrasing surfaces the structural cause
  first.
  """

  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  @endpoint CodeMySpecLocalWeb.Endpoint

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    account = Fixtures.account_with_owner_fixture(user)
    scope_after_account = Fixtures.user_scope_fixture(user, account)
    Fixtures.select_active_account(scope_after_account, account.id)

    stub_dir = Path.join(System.tmp_dir!(), "projector-#{System.unique_integer([:positive])}")
    File.mkdir_p!(stub_dir)
    File.write!(Path.join(stub_dir, "mix.exs"), "# stub for WorkingDir plug\n")
    on_exit(fn -> File.rm_rf(stub_dir) end)

    env = Fixtures.memory_environment_fixture(working_dir: stub_dir)

    project =
      Fixtures.project_fixture(scope_after_account, account_id: account.id, local_path: stub_dir)

    Fixtures.register_environment(project.id, env)
    on_exit(fn -> Fixtures.unregister_environment(project.id) end)

    scope =
      user
      |> Fixtures.user_scope_fixture(account, project)
      |> Map.put(:cwd, stub_dir)
      |> Map.put(:environment, env)

    Fixtures.select_active_project(scope, project.id)

    token = Fixtures.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)

    %{conn: conn, scope: scope, env: env, project: project}
  end

  describe "project_graph/1 structural invariants" do
    test "every rendered edge endpoint is in the rendered node set", ctx do
      sync_three_children(ctx)
      graph = GraphProjector.project_graph(ctx.scope)

      node_keys = MapSet.new(graph.nodes, & &1.key)

      dangling =
        Enum.filter(graph.edges, fn e ->
          not MapSet.member?(node_keys, e.source) or
            not MapSet.member?(node_keys, e.target)
        end)

      assert dangling == [], "dangling edges: #{inspect(dangling)}"
    end

    test "no duplicate node keys", ctx do
      sync_three_children(ctx)
      graph = GraphProjector.project_graph(ctx.scope)

      counts = Enum.frequencies_by(graph.nodes, & &1.key)
      duplicates = for {k, c} <- counts, c > 1, do: {k, c}

      assert duplicates == [], "duplicate keys: #{inspect(duplicates)}"
    end

    test "every node has finite numeric coordinates", ctx do
      sync_three_children(ctx)
      graph = GraphProjector.project_graph(ctx.scope)

      bad =
        Enum.filter(graph.nodes, fn n ->
          x = n.attributes.x
          y = n.attributes.y
          not (is_number(x) and is_number(y))
        end)

      assert bad == [], "non-numeric coords on: #{inspect(Enum.map(bad, & &1.key))}"
    end

    test "rendering is deterministic for the same scope", ctx do
      sync_three_children(ctx)

      a = GraphProjector.project_graph(ctx.scope)
      b = GraphProjector.project_graph(ctx.scope)

      assert Enum.sort_by(a.nodes, & &1.key) == Enum.sort_by(b.nodes, & &1.key)
      assert Enum.sort_by(a.edges, & &1.key) == Enum.sort_by(b.edges, & &1.key)
    end
  end

  describe "project_graph/1 topology-flow properties" do
    test "intra-entity edges flow downward or rightward (toward target)", ctx do
      sync_three_children(ctx)
      %{nodes: nodes, edges: edges} = Requirements.project_graph(ctx.scope)
      sigma = GraphProjector.project_graph(ctx.scope)

      by_key = Map.new(sigma.nodes, &{&1.key, &1})

      intra =
        edges
        |> Enum.reject(fn e ->
          {ft, _, _} = e.from
          {tt, _, _} = e.to
          ft != tt
        end)

      # Layout invariant: intra-entity dependency edges must flow either
      # DOWNWARD (source.y > target.y, vertical-band layouts like the
      # story/component zones) or RIGHTWARD when source and target sit
      # in the same horizontal band (source.y == target.y, source.x <
      # target.x — the horizontal layout used by the project chain at
      # top/bottom). Anything else is an upward/leftward arrow, which
      # contradicts the visual dependency flow.
      violations =
        intra
        |> Enum.map(fn e -> {sigma_key(e.from), sigma_key(e.to)} end)
        |> Enum.flat_map(fn {f, t} ->
          with %{} = source <- Map.get(by_key, f),
               %{} = target <- Map.get(by_key, t),
               false <- flows_correctly?(source.attributes, target.attributes) do
            [{f, t, source.attributes, target.attributes}]
          else
            _ -> []
          end
        end)

      _ = nodes
      assert violations == [], "edges with flipped flow: #{inspect(violations)}"
    end

    defp flows_correctly?(%{x: sx, y: sy}, %{x: tx, y: ty}) do
      cond do
        sy > ty -> true
        sy == ty and sx < tx -> true
        true -> false
      end
    end

    test "fan-in nodes (indegree >= 2) sit at-or-below all their sources", ctx do
      sync_three_children(ctx)
      %{nodes: nodes, edges: edges} = Requirements.project_graph(ctx.scope)
      sigma = GraphProjector.project_graph(ctx.scope)

      indeg = Topology.indegree(nodes, edges)
      by_sigma = Map.new(sigma.nodes, &{&1.key, &1})

      fan_in_keys =
        nodes
        |> Enum.filter(fn n -> Map.get(indeg, {n.entity_type, n.entity_id, n.name}, 0) >= 2 end)
        |> Enum.map(&sigma_key({&1.entity_type, &1.entity_id, &1.name}))
        |> Enum.filter(&Map.has_key?(by_sigma, &1))

      violations =
        Enum.flat_map(fan_in_keys, fn fk ->
          target_y = by_sigma[fk].attributes.y

          edges
          |> Enum.filter(fn e -> sigma_key(e.to) == fk end)
          |> Enum.flat_map(fn e ->
            sk = sigma_key(e.from)

            case Map.get(by_sigma, sk) do
              %{attributes: %{y: source_y}} when source_y <= target_y ->
                [{sk, fk, source_y, target_y}]

              _ ->
                []
            end
          end)
        end)

      assert violations == [], "fan-in not below sources: #{inspect(violations)}"
    end

    test "all nodes for a single entity sit on the same x-coordinate column", ctx do
      sync_three_children(ctx)
      sigma = GraphProjector.project_graph(ctx.scope)

      offenders =
        sigma.nodes
        |> Enum.group_by(fn n ->
          {n.attributes[:entity_type], n.attributes[:entity_id]}
        end)
        |> Enum.reject(fn {{type, id}, _} -> is_nil(type) or is_nil(id) end)
        |> Enum.flat_map(fn {key, group_nodes} ->
          xs = group_nodes |> Enum.map(& &1.attributes.x) |> Enum.uniq()
          if length(xs) > 1, do: [{key, xs}], else: []
        end)

      assert offenders == [], "entities with split x: #{inspect(offenders)}"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp sync_three_children(ctx) do
    write_specs(ctx.env, [
      {"Reservations", :context, []},
      {"Reservations.Booking", :schema, []},
      {"Reservations.BookingRepo", :repository, []},
      {"Reservations.PricingService", :service, []}
    ])

    {:ok, sync_live, _html} =
      live(ctx.conn, "/projects/#{ctx.project.name}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()
    :ok
  end

  defp write_specs(env, specs) do
    Enum.each(specs, fn {module_name, type, deps} ->
      spec_content =
        case type do
          :context -> Content.context_spec(module_name, type: "context", dependencies: deps)
          atom when is_atom(atom) -> Content.child_spec(module_name, type: Atom.to_string(atom), dependencies: deps)
        end

      :ok = Environments.write_file(env, Content.spec_path(module_name), spec_content)
      :ok = Environments.write_file(env, Content.impl_path(module_name), Content.impl_file(module_name))
    end)
  end

  defp sigma_key({type, id, name}) do
    "#{type}_#{sanitize_id(id)}_#{name}"
  end

  defp sanitize_id(id) when is_integer(id), do: "#{id}"
  defp sanitize_id(id) when is_binary(id), do: String.replace(id, "-", "")
end
