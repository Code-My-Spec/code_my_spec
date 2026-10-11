defmodule CodeMySpec.Requirements.EdgesDerivedPerEntityMatchThePassTest do
  @moduledoc """
  The edges derived one entity at a time are the edges the pass draws.

  `Edges.over/4` reduces each entity's edges against reachability over the
  component side. `RequirementGraph.compute_edges/3` reduces the whole set at
  once. The first is what lets a component appearing cost its own edges
  rather than a reduction over every edge at every vantage, and it is exact
  only because of the three facts about the templates that `Edges` states.

  So this holds the two together on a shape that leans on each of them: a
  dependency chain three contexts long, so a story's kickoff is pruned to the
  chain's head; a sibling dependency inside a context; a container surface and
  a leaf surface, so both exit shapes are drawn; a story with no component; a
  LiveView surface depending on a context; an infrastructure component with no
  nodes to draw to; and stories at all, so the project's `qa_setup →
  qa_journey_plan` is carried by them rather than drawn.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Configurations
  alias CodeMySpec.ConfigurationsFixtures
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.Edges
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    {:ok, scope: setup_project()}
  end

  describe "a story on a surface no other component touches" do
    # A lone LiveView has one requirement and no dependency, parent or child,
    # so no component-side edge names its node at all. The kickoff lands on
    # that node and the exit leaves from it — a path of length two through
    # a node the component graph has never heard of — and the pass drops the
    # story's own kickoff-to-exit edge for it. Measured on dev before this
    # case existed: 34 stories carrying an edge the pass had dropped.
    test "still has its chain cut where the surface carries it", %{scope: scope} do
      components = shape(scope)
      stories = stories(scope, components)
      {pass, ours} = both(scope)

      assert MapSet.new(ours) == MapSet.new(pass), difference(pass, ours)

      lone = stories.on_lone_surface

      refute chain_intact?(pass, lone),
             "the lone story's own chain should be cut where the surface carries it"

      assert chain_intact?(pass, stories.unlinked),
             "a story with no component has nothing to carry it"
    end
  end

  describe "a project with components and no stories" do
    test "is drawn as the pass draws it, project chain included", %{scope: scope} do
      shape(scope)
      {pass, ours} = both(scope)

      assert MapSet.new(ours) == MapSet.new(pass), difference(pass, ours)

      assert project_edge(scope, "qa_setup", "qa_journey_plan") in pass,
             "with no story to carry it, the project's own edge has to"
    end
  end

  describe "a project with stories" do
    test "is drawn as the pass draws it", %{scope: scope} do
      components = shape(scope)
      stories = stories(scope, components)
      {pass, ours} = both(scope)

      assert MapSet.new(ours) == MapSet.new(pass), difference(pass, ours)

      seams = MapSet.new(pass, fn %{from: {f, _, _}, to: {t, _, _}} -> {f, t} end)

      for seam <- [
            {"story", "component"},
            {"component", "story"},
            {"component", "component"},
            {"project", "story"},
            {"story", "project"},
            {"story", "story"},
            {"project", "project"}
          ] do
        assert seam in seams,
               "the fixture draws no #{inspect(seam)} edge, so agreeing on it proves nothing"
      end

      refute project_edge(scope, "qa_setup", "qa_journey_plan") in pass,
             "a story carries the project from qa_setup to qa_journey_plan, so the edge is redundant"

      # The chain: Notifications → Billing → Accounts. The story on
      # Notifications kicks off inside the head of the chain — a context's
      # kickoff lands on its children — and nowhere else.
      kicked = kicked_off(pass, stories.on_chain)

      assert kicked != [] and Enum.all?(kicked, &(&1 in family(components, :head))),
             "the kickoff should land only in the chain's head, got #{inspect(kicked)}"
    end

    test "a node with no row cannot carry a path", %{scope: scope} do
      components = shape(scope)
      stories = stories(scope, components)
      {:ok, ctx} = Preloader.load(scope)
      config = Configurations.get_or_create(scope)
      {nodes, whole} = RequirementGraph.compute_topology(scope, ctx, config)

      # Billing's own rows go: the middle of the chain has nothing to land on.
      left = Enum.reject(nodes, &(&1.entity_id == components.billing.id))
      assert length(left) < length(nodes)
      keys = MapSet.new(left, &Topology.node_key/1)

      pass = RequirementGraph.edges_over(scope, left, ctx, config)
      ours = Edges.over(scope, ctx, config, &MapSet.member?(keys, &1))

      assert MapSet.new(ours) == MapSet.new(pass), difference(pass, ours)

      # Billing's exit is its own last requirement, so with its rows gone the
      # chain is cut there and the tail's kickoff is no longer redundant.
      kicked = kicked_off(pass, stories.on_chain)

      assert Enum.any?(kicked, &(&1 in family(components, :head))) and
               Enum.any?(kicked, &(&1 in family(components, :tail))),
             "with Billing gone the kickoff has to reach both halves, got #{inspect(kicked)}"

      assert MapSet.new(pass) != MapSet.new(whole),
             "the filter changed nothing, so it was not what this case exercises"
    end
  end

  defp kicked_off(edges, story_id) do
    for %{from: {"story", ^story_id, _}, to: {"component", id, _}} <- edges, uniq: true, do: id
  end

  defp family(components, :head),
    do: [components.accounts.id, components.user.id, components.user_repository.id]

  defp family(components, :tail), do: [components.notifications.id, components.mailer.id]

  # Whether the story's own edges still run unbroken from its first
  # requirement to its last — false once the components carry a stretch.
  defp chain_intact?(edges, story_id) do
    own =
      for %{from: {"story", ^story_id, _} = f, to: {"story", ^story_id, _} = t} <- edges,
          do: %{from: f, to: t}

    reach = Topology.reach(own)
    # Issue triage now gives component_linked a separate path into readiness.
    # The path replaced by component work is specifically BDD → ready_for_qa.
    Topology.reaches?(
      reach,
      {"story", story_id, "bdd_specs_exist"},
      Topology.mask(reach, [{"story", story_id, "ready_for_qa"}])
    )
  end

  defp both(scope) do
    {:ok, ctx} = Preloader.load(scope)
    config = Configurations.get_or_create(scope)
    {nodes, pass} = RequirementGraph.compute_topology(scope, ctx, config)
    keys = MapSet.new(nodes, &Topology.node_key/1)
    {pass, Edges.over(scope, ctx, config, &MapSet.member?(keys, &1))}
  end

  defp difference(pass, ours) do
    pass = MapSet.new(pass)
    ours = MapSet.new(ours)

    """
    The per-entity derivation and the pass disagree.

    missing (the pass draws them, the derivation does not):
    #{lines(MapSet.difference(pass, ours))}
    extra (the derivation draws them, the pass does not):
    #{lines(MapSet.difference(ours, pass))}
    """
  end

  defp lines(edges) do
    edges
    |> Enum.take(12)
    |> Enum.map_join("\n", fn %{from: from, to: to} -> "  #{label(from)} -> #{label(to)}" end)
  end

  defp label({type, id, name}), do: "#{type}:#{id}/#{name}"

  defp project_edge(scope, from, to) do
    id = scope.active_project_id
    %{from: {"project", id, from}, to: {"project", id, to}}
  end

  defp shape(scope) do
    accounts = component(scope, "Accounts", "context")
    user = child(scope, "Accounts.User", "schema", accounts)
    user_repository = child(scope, "Accounts.UserRepository", "repository", accounts)
    billing = component(scope, "Billing", "context")
    invoice = child(scope, "Billing.Invoice", "schema", billing)
    notifications = component(scope, "Notifications", "context")
    mailer = child(scope, "Notifications.Mailer", "schema", notifications)
    home_live = component(scope, "Web.HomeLive", "liveview")
    about_live = component(scope, "Web.AboutLive", "liveview")
    plumbing = component(scope, "Plumbing", "infrastructure")

    depend(scope, billing, accounts)
    depend(scope, notifications, billing)
    depend(scope, user_repository, user)
    depend(scope, home_live, notifications)
    depend(scope, billing, plumbing)

    %{
      accounts: accounts,
      user: user,
      user_repository: user_repository,
      billing: billing,
      invoice: invoice,
      notifications: notifications,
      mailer: mailer,
      home_live: home_live,
      about_live: about_live
    }
  end

  defp stories(scope, components) do
    %{
      on_chain: story(scope, "Notify on invoice", components.notifications.id),
      on_container: story(scope, "Sign up", components.accounts.id),
      also_on_container: story(scope, "Sign in", components.accounts.id),
      on_leaf: story(scope, "Print an invoice", components.invoice.id),
      on_surface: story(scope, "See the home page", components.home_live.id),
      on_lone_surface: story(scope, "Read about us", components.about_live.id),
      unlinked: story(scope, "Something not yet placed", nil)
    }
  end

  defp story(scope, title, component_id) do
    {:ok, story} =
      Stories.create_story(scope, %{
        ready_for_dev: true,
        title: title,
        description: "As a user, #{title}",
        acceptance_criteria: ["It works"],
        component_id: component_id
      })

    story.id
  end

  defp component(scope, module_name, type) do
    {:ok, component} =
      Components.create_component(scope, %{
        name: module_name |> String.split(".") |> List.last(),
        type: type,
        module_name: module_name
      })

    component
  end

  defp child(scope, module_name, type, parent) do
    component = component(scope, module_name, type)

    {:ok, component} =
      Components.update_component(scope, component, %{parent_component_id: parent.id})

    component
  end

  defp depend(scope, source, target) do
    {:ok, _dependency} =
      Components.create_dependency(scope, %{
        source_component_id: source.id,
        target_component_id: target.id
      })
  end

  defp setup_project do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")
    %Scope{} = scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope =
      put_fixture_environment(
        %Scope{scope | active_project: project},
        Environment.new(:local, tmp_dir)
      )

    ConfigurationsFixtures.ensure_configuration!(scope)
  end
end
