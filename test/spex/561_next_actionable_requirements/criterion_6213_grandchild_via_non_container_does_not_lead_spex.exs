defmodule CodeMySpecSpex.Story561.Criterion6213Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 6213 — A grandchild component nested under a non-container
  intermediate (e.g., `Context → Behaviour → Implementation`) does
  not appear in the next-actionable wave.

  Background:

    Graph instantiation only stamps `:child` nodes for components
    whose parent is a *container* type (a type whose template defines
    `:child`-scoped requirements — see `ComponentRegistry.has_children?/1`).
    A grandchild whose immediate parent is a non-container (behaviour,
    schema, module, etc.) is stamped standalone with `default_graph()`
    — disconnected from the story's surface chain.

    Priority inheritance via `parent_component_id`, however, walks the
    chain recursively. Without a guard this leaks the priority of a
    far ancestor (the linked context) past the non-container parent
    into the grandchild. Once its `spec_valid` is satisfied, its
    `implementation_file` becomes actionable — even though no story
    asks for it and no kickoff edge connects it.

    This criterion locks in that the parent-chain spread must stop at
    non-container parents, so grandchildren of this shape stay
    untethered and are filtered from the wave.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Grandchild via a non-container parent is kept out of the wave" do
    scenario "linked context priority does not leak past a behaviour intermediate" do
      given_ "a priority-1 linked context, a behaviour child, and a grandchild implementation",
             context do
        env = context.environment

        # Linked context: gets priority via the story below.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("LinkedContext"),
            Content.context_spec("LinkedContext", type: "context", dependencies: [])
          )

        :ok =
          Environments.write_file(
            env,
            Content.impl_path("LinkedContext"),
            Content.impl_file("LinkedContext")
          )

        # Behaviour child of LinkedContext. As a graph-child of a
        # container, it gets `:child`-scoped template nodes from the
        # context_graph; the behaviour's own type is non-container.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("LinkedContext.SourceBehaviour"),
            Content.child_spec("LinkedContext.SourceBehaviour",
              type: "behaviour",
              dependencies: []
            )
          )

        :ok =
          Environments.write_file(
            env,
            Content.impl_path("LinkedContext.SourceBehaviour"),
            Content.impl_file("LinkedContext.SourceBehaviour")
          )

        # Grandchild: parent is the behaviour (a non-container).
        # Spec exists (so spec_valid passes) but impl does NOT — its
        # implementation_file is therefore the unsatisfied node we
        # expect to be filtered as untethered.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("LinkedContext.SourceBehaviour.ElixirForum"),
            Content.child_spec("LinkedContext.SourceBehaviour.ElixirForum",
              type: "schema",
              dependencies: []
            )
          )

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        linked = Fixtures.get_component_by_module_name(context.scope, "LinkedContext")

        grandchild =
          Fixtures.get_component_by_module_name(
            context.scope,
            "LinkedContext.SourceBehaviour.ElixirForum"
          )

        StoryHelpers.create_and_link(context.scope, "LinkedContext",
          title: "Linked story",
          description: "As a user, I want the linked context to drive priority.",
          acceptance_criteria: ["Linked ships"],
          priority: 1
        )

        {:ok, Map.merge(context, %{linked: linked, grandchild: grandchild})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the grandchild is not in the wave", context do
        text = context.response_text

        refute text =~ "entity_id=`#{context.grandchild.id}`",
               "grandchild via a non-container parent should not be in next_actionable. Response: #{text}"

        {:ok, context}
      end
    end
  end
end
