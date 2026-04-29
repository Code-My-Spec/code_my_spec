defmodule CodeMySpecSpex.GraphGivens do
  @moduledoc """
  Shared given steps for the requirements graph stories
  (561, 562, 671).

  Each given assembles a topology by writing well-formed spec files
  into the in-memory environment and triggering the real sync
  pipeline via the `/sync` LiveView. Sync derives parent/child
  relationships from module nesting and dependencies from each
  spec's `## Dependencies` section, so topology emerges from the
  fixture content — no `CreateDependency` MCP calls needed.

  Import alongside `CodeMySpecSpex.SharedGivens`:

      defmodule CodeMySpecSpex.Story562.SomeSpex do
        use CodeMySpecSpex.Case

        import CodeMySpecSpex.SharedGivens
        import CodeMySpecSpex.GraphGivens

        spex "..." do
          scenario "..." do
            given_ :context_with_three_children
            # ...
          end
        end
      end

  ## Defined givens

  - `:context_with_three_children` — `Reservations` context with
    three child components: a schema, a repository, and a service.
    All synced and present in the DB. Produces
    `context.parent_context`, `context.child_schema`,
    `context.child_repository`, `context.child_service`.

  - `:two_independent_sibling_schemas` — `Catalog` context with two
    sibling schemas (`Catalog.Product`, `Catalog.Category`) that have
    no dependency between them. Produces `context.parent_context`,
    `context.sibling_a`, `context.sibling_b`.

  - `:two_siblings_one_depends_on_other` — `Catalog` context with
    three siblings: `Catalog.Product` (no deps), `Catalog.Category`
    (no deps), and `Catalog.ProductRepo` (declares
    `Catalog.Product` as a dependency). Produces
    `context.independent_a`, `context.independent_b`,
    `context.dependent`, `context.dependency`.

  - `:cross_context_dependency` — two contexts where the second
    depends on the first. `Users` (with one schema child,
    `Users.Account`) and `Stories` (with one schema child,
    `Stories.Story`); `Stories` declares `Users` as a dependency.
    Produces `context.users_context`, `context.users_child`,
    `context.stories_context`, `context.stories_child`.

  - `:orphan_component` — a component with no parent context and no
    story link. Created via `CreateComponent` (sync won't manufacture
    an orphan from nothing). Produces `context.orphan`.

  - `:story_with_liveview_surface` — a story linked to a LiveView
    surface (`Marketing.HomeLive`) that depends on a context
    (`Marketing`). Produces `context.surface_liveview`,
    `context.dep_context`, `context.story`.

  - `:project_with_four_stories` — a project topology with four
    LiveView surfaces (`AppOne.OneLive` through `AppFour.FourLive`),
    each linked to one story. Produces `context.surfaces` (list of
    components) and `context.stories` (list of stories).

  - `:fully_satisfied_project` — full project satisfaction state.
    Composes existing bridge fixtures (`SetupFixtures`,
    `TechnicalStrategyFixtures`, `CodeGenerationFixtures`,
    `QaIntegrationPlanFixtures`, `ArchitectureFixtures`) plus
    persona MCP creation, story MCP creation, and inline
    qa/journey/bdd file writes. Lands the project in a state
    where `next_actionable/1` returns `[]` (or as close as we
    can get without reproducing test_spec_alignment). Produces
    `context.component`, `context.story`, `context.persona_slug`,
    `context.persona_id`. See `FullSatisfactionFixtures` for the
    composition details and known gaps.

  Add new givens here only after a third spec duplicates setup
  inside an inline given_ block.
  """

  use SexySpex.Givens

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  # -- Topology: one context, three children --

  register_given :context_with_three_children, context do
    write_specs(context.environment, [
      {"Reservations", :context, []},
      {"Reservations.Booking", :schema, []},
      {"Reservations.BookingRepo", :repository, []},
      {"Reservations.PricingService", :service, []}
    ])

    sync_project(context)

    parent = Fixtures.get_component_by_module_name(context.scope, "Reservations")
    schema = Fixtures.get_component_by_module_name(context.scope, "Reservations.Booking")
    repo = Fixtures.get_component_by_module_name(context.scope, "Reservations.BookingRepo")
    service = Fixtures.get_component_by_module_name(context.scope, "Reservations.PricingService")

    {:ok,
     Map.merge(context, %{
       parent_context: parent,
       child_schema: schema,
       child_repository: repo,
       child_service: service
     })}
  end

  # -- Topology: two independent siblings --

  register_given :two_independent_sibling_schemas, context do
    write_specs(context.environment, [
      {"Catalog", :context, []},
      {"Catalog.Product", :schema, []},
      {"Catalog.Category", :schema, []}
    ])

    sync_project(context)

    parent = Fixtures.get_component_by_module_name(context.scope, "Catalog")
    a = Fixtures.get_component_by_module_name(context.scope, "Catalog.Product")
    b = Fixtures.get_component_by_module_name(context.scope, "Catalog.Category")

    {:ok,
     Map.merge(context, %{
       parent_context: parent,
       sibling_a: a,
       sibling_b: b
     })}
  end

  # -- Topology: three siblings, one depends on another --

  register_given :two_siblings_one_depends_on_other, context do
    write_specs(context.environment, [
      {"Catalog", :context, []},
      {"Catalog.Product", :schema, []},
      {"Catalog.Category", :schema, []},
      {"Catalog.ProductRepo", :repository, ["Catalog.Product"]}
    ])

    sync_project(context)

    independent_a = Fixtures.get_component_by_module_name(context.scope, "Catalog.Category")
    independent_b = Fixtures.get_component_by_module_name(context.scope, "Catalog.Product")
    dependent = Fixtures.get_component_by_module_name(context.scope, "Catalog.ProductRepo")

    {:ok,
     Map.merge(context, %{
       independent_a: independent_a,
       independent_b: independent_b,
       dependent: dependent,
       dependency: independent_b
     })}
  end

  # -- Topology: cross-context dependency --

  register_given :cross_context_dependency, context do
    write_specs(context.environment, [
      {"Users", :context, []},
      {"Users.Account", :schema, []},
      {"Stories", :context, ["Users"]},
      {"Stories.Story", :schema, []}
    ])

    sync_project(context)

    users_ctx = Fixtures.get_component_by_module_name(context.scope, "Users")
    users_child = Fixtures.get_component_by_module_name(context.scope, "Users.Account")
    stories_ctx = Fixtures.get_component_by_module_name(context.scope, "Stories")
    stories_child = Fixtures.get_component_by_module_name(context.scope, "Stories.Story")

    {:ok,
     Map.merge(context, %{
       users_context: users_ctx,
       users_child: users_child,
       stories_context: stories_ctx,
       stories_child: stories_child
     })}
  end

  # -- Topology: orphan component --

  register_given :orphan_component, context do
    orphan =
      ComponentHelpers.create(context.scope,
        type: "context",
        module_name: "OrphanContext",
        name: "Orphan Context",
        description: "An orphan context with no story linkage and no parent."
      )

    {:ok, Map.put(context, :orphan, orphan)}
  end

  # -- Topology: story → LiveView surface → context dep --

  register_given :story_with_liveview_surface, context do
    write_specs(context.environment, [
      {"Marketing", :context, []},
      {"Marketing.HomeLive", :liveview, ["Marketing"]}
    ])

    sync_project(context)

    surface = Fixtures.get_component_by_module_name(context.scope, "Marketing.HomeLive")
    dep_context = Fixtures.get_component_by_module_name(context.scope, "Marketing")

    story =
      StoryHelpers.create_and_link(context.scope, "Marketing.HomeLive",
        title: "User visits the home page",
        description: "The home page renders the marketing landing.",
        acceptance_criteria: ["Home page renders"]
      )

    {:ok,
     Map.merge(context, %{
       surface_liveview: surface,
       dep_context: dep_context,
       story: story
     })}
  end

  # -- Full satisfaction state --

  register_given :fully_satisfied_project, context do
    {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply(context)}
  end

  # -- Topology: four stories, four LiveView surfaces --

  register_given :project_with_four_stories, context do
    write_specs(context.environment, [
      {"AppOne", :context, []},
      {"AppOne.OneLive", :liveview, ["AppOne"]},
      {"AppTwo", :context, []},
      {"AppTwo.TwoLive", :liveview, ["AppTwo"]},
      {"AppThree", :context, []},
      {"AppThree.ThreeLive", :liveview, ["AppThree"]},
      {"AppFour", :context, []},
      {"AppFour.FourLive", :liveview, ["AppFour"]}
    ])

    sync_project(context)

    surfaces =
      ["AppOne.OneLive", "AppTwo.TwoLive", "AppThree.ThreeLive", "AppFour.FourLive"]
      |> Enum.map(&Fixtures.get_component_by_module_name(context.scope, &1))

    stories =
      Enum.with_index(surfaces, 1)
      |> Enum.map(fn {surface, idx} ->
        StoryHelpers.create_and_link(context.scope, surface.module_name,
          title: "Story #{idx}",
          description: "A story for surface #{surface.module_name}",
          acceptance_criteria: ["Surface #{idx} renders"]
        )
      end)

    {:ok, Map.merge(context, %{surfaces: surfaces, stories: stories})}
  end

  # -- Helpers --

  # Write a list of {module_name, type, deps} tuples as spec + impl
  # files into the environment. Each spec lives at the canonical path
  # derived from the module name.
  defp write_specs(env, specs) do
    Enum.each(specs, fn {module_name, type, deps} ->
      spec_content =
        case type do
          :context -> Content.context_spec(module_name, type: "context", dependencies: deps)
          :live_context -> Content.context_spec(module_name, type: "live_context", dependencies: deps)
          :liveview -> Content.liveview_spec(module_name, dependencies: deps)
          :liveview_component -> Content.liveview_spec(module_name, type: "liveview_component", dependencies: deps)
          atom when is_atom(atom) -> Content.child_spec(module_name, type: Atom.to_string(atom), dependencies: deps)
        end

      :ok = Environments.write_file(env, Content.spec_path(module_name), spec_content)
      :ok = Environments.write_file(env, Content.impl_path(module_name), Content.impl_file(module_name))
    end)
  end

  # Trigger sync via the real /sync LiveView surface.
  defp sync_project(context) do
    {:ok, sync_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/sync")

    sync_live |> element("button[phx-click='sync']") |> render_click()
    :ok
  end
end
