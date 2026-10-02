defmodule CodeMySpecSpex.ComponentGraphHelpers do
  @moduledoc """
  Builds a project's component graph the way agents and engineers do, and
  reads it back off the surfaces they read.

  Components as records (3aeb66cf) means a graph arrives three ways: authored
  through the tools (`design!/4`), authored through a proposal
  (`execute_proposal`), or discovered from code by a sync. Each builder
  here drives the real surface and asserts its own success, so a refused setup
  fails where it was refused rather than somewhere downstream.

  Reads go through `show_architecture` (edges between contexts and surface
  components, as Mermaid), `get_component` and `list_components`.
  """

  import ExUnit.Assertions
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal
  alias CodeMySpec.McpServers.Components.Tools.AddDependency
  alias CodeMySpec.McpServers.Components.Tools.GetComponent
  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias CodeMySpec.McpServers.Components.Tools.ShowArchitecture
  alias CodeMySpec.McpServers.Components.Tools.UpdateComponent
  alias CodeMySpec.McpServers.Requirements.Tools.ShowRequirement
  alias CodeMySpec.McpServers.Requirements.Tools.SyncProject
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures

  @doc "The project's application module name, as the agent would write it."
  def app(context), do: context.project.module_name || "MyApp"

  defp frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  defp ok!(reply, what) do
    refute reply.isError, "#{what} was refused: #{response_text(reply)}"
    reply
  end

  # -- Writing ----------------------------------------------------------------

  @doc "`add_dependency` between two components, by id."
  def depend!(context, source, target) do
    {:reply, reply, _} =
      AddDependency.execute(
        %{source_component_id: source.id, target_component_id: target.id},
        frame(context)
      )

    ok!(reply, "add_dependency #{source.module_name} -> #{target.module_name}")
  end

  @doc """
  Authors `module` through `create_component`, then `add_dependency` to each of
  `dependencies` (module names, already designed). How an architecture is
  written now; returns the component. `opts` may set `:type` (default
  `"context"`), `:description` and `:parent` (a module name).
  """
  def design!(context, module, dependencies \\ [], opts \\ []) do
    component =
      ComponentHelpers.create(
        context.scope,
        %{
          name: module |> String.split(".") |> List.last(),
          module_name: module,
          type: Keyword.get(opts, :type, "context"),
          description: Keyword.get(opts, :description, "#{module}, as designed.")
        }
        |> put_parent(context, Keyword.get(opts, :parent))
      )

    for dependency <- dependencies,
        do: depend!(context, component, by_name!(context, dependency))

    component
  end

  @doc """
  Designs each `{module, type, dependencies}` not yet designed, under its
  nearest existing ancestor by module name, writes its code, then adds every
  listed dependency. A built project, as far as the graph can tell. A module
  already designed keeps its record and gains the dependencies.
  """
  def design_coded!(context, components) do
    for {module, type, _dependencies} <- components do
      unless Fixtures.get_component_by_module_name(context.scope, module),
        do:
          design!(context, module, [],
            type: to_string(type),
            parent: nearest_ancestor(context, module)
          )

      implementation!(context, module)
    end

    for {module, _type, dependencies} <- components,
        dependency <- dependencies,
        do: depend!(context, by_name!(context, module), by_name!(context, dependency))

    :ok
  end

  defp nearest_ancestor(context, module) do
    parts = String.split(module, ".")

    (length(parts) - 1)..1//-1
    |> Enum.map(&Enum.join(Enum.take(parts, &1), "."))
    |> Enum.find(&Fixtures.get_component_by_module_name(context.scope, &1))
  end

  defp put_parent(attrs, _context, nil), do: attrs

  defp put_parent(attrs, context, parent),
    do: Map.put(attrs, :parent_component_id, by_name!(context, parent).id)

  defp by_name!(context, module) do
    component = Fixtures.get_component_by_module_name(context.scope, module)
    assert component, "#{module} has not been designed yet"
    component
  end

  @doc """
  A spec file for `module`, declaring `dependencies` (module names). What an
  agent writing specs by hand produces. Specs describe nothing to a sync any
  more (3aeb66cf, step 7c); this is for showing that they don't.
  `opts` may set the spec's `:type` and `:description`.
  """
  def spec!(context, module, dependencies \\ [], opts \\ []) do
    deps =
      case dependencies do
        [] -> "- None"
        list -> Enum.map_join(list, "\n", &"- #{&1}")
      end

    :ok =
      Environments.write_file(context.environment, spec_path(module), """
      # #{module}

      #{Keyword.get(opts, :description, "#{module}, written as a spec.")}

      ## Type

      #{Keyword.get(opts, :type, "context")}

      ## Functions

      ## Dependencies

      #{deps}
      """)
  end

  @doc "Removes the spec file `spec!/4` wrote for `module`."
  def remove_spec!(context, module),
    do: :ok = Environments.delete_file(context.environment, spec_path(module))

  @doc "An implementation file declaring `module`, with no spec beside it."
  def implementation!(context, module) do
    :ok =
      Environments.write_file(
        context.environment,
        "lib/#{Macro.underscore(module)}.ex",
        "defmodule #{module} do\n  @moduledoc false\nend\n"
      )
  end

  @doc "Removes the implementation file `implementation!/2` wrote for `module`."
  def remove_implementation!(context, module),
    do: :ok = Environments.delete_file(context.environment, "lib/#{Macro.underscore(module)}.ex")

  @doc "A full sync, through `sync_project`."
  def sync!(context) do
    {:reply, reply, _} = SyncProject.execute(%{}, frame(context))
    ok!(reply, "sync_project")
  end

  @doc "Writes `markdown` as the proposal and runs `execute_proposal` on it."
  def execute_proposal!(context, markdown) do
    :ok = Environments.write_file(context.environment, Fixtures.proposal_path(), markdown)
    {:reply, reply, _} = ExecuteProposal.execute(%{}, frame(context))
    ok!(reply, "execute_proposal")
  end

  @doc """
  Proposal markdown: one surface component carrying `story_number`, the given
  contexts (`{name, children}` pairs, children as `{name, type}`), and
  `dependencies` as `{from, to}` pairs. Every name is relative to the app.
  Validation refuses an orphan, so every context has to be reachable from the
  surface through `dependencies`.
  """
  def proposal(context, story_number, contexts, dependencies) do
    app = app(context)

    contexts_md =
      Enum.map_join(contexts, "\n", fn {name, children} ->
        children_md = children_md(app, name, children)

        """
        ### #{app}.#{name}

        - **Type:** context
        - **Description:** #{name}

        #{children_md}
        """
      end)

    deps_md =
      Enum.map_join(dependencies, "\n", fn {from, to} ->
        "- #{qualify(app, from)} -> #{qualify(app, to)}"
      end)

    """
    # Architecture Proposal

    ## Surface Components

    ### #{app}Web.FeatureLive

    - **Type:** liveview
    - **Description:** The feature
    - **Stories:** #{story_number}

    ## Contexts

    #{contexts_md}
    ## Dependencies

    #{deps_md}
    """
  end

  defp children_md(_app, _name, []), do: ""

  defp children_md(app, name, children) do
    lines =
      Enum.map_join(children, "\n", fn {child, type} ->
        "- #{app}.#{name}.#{child} (#{type}) - #{child}"
      end)

    "**Children:**\n" <> lines <> "\n"
  end

  defp qualify(app, "FeatureLive"), do: "#{app}Web.FeatureLive"
  defp qualify(app, name), do: "#{app}.#{name}"

  # -- Reading ----------------------------------------------------------------

  @doc "`show_architecture`'s Mermaid."
  def architecture(context) do
    {:reply, reply, _} = ShowArchitecture.execute(%{}, frame(context))
    response_text(reply)
  end

  @doc "The Mermaid edge line for `from -> to`, names relative to the app."
  def edge(context, from, to) do
    app = app(context)
    node = &(qualify(app, &1) |> String.replace(".", "_") |> String.downcase())
    "#{node.(from)} --> #{node.(to)}"
  end

  @doc "`show_requirement` for the project's `architecture_designed`, as text."
  def architecture_designed(context) do
    {:reply, reply, _} =
      ShowRequirement.execute(
        %{name: "architecture_designed", entity_type: "project"},
        frame(context)
      )

    response_text(reply)
  end

  @doc "`update_component` to `type` for the component named `module`."
  def retype!(context, module, type) do
    id = Fixtures.get_component_by_module_name(context.scope, module).id
    {:reply, reply, _} = UpdateComponent.execute(%{id: id, type: type}, frame(context))
    ok!(reply, "update_component #{module} -> #{type}")
  end

  @doc "`list_components`' text."
  def listed(context) do
    {:reply, reply, _} = ListComponents.execute(%{}, frame(context))
    response_text(reply)
  end

  @doc "`get_component` for the component named `module`, decoded."
  def component(context, module) do
    id = Fixtures.get_component_by_module_name(context.scope, module).id
    {:reply, reply, _} = GetComponent.execute(%{component_id: id}, frame(context))
    reply |> ok!("get_component #{module}") |> response_text() |> Jason.decode!()
  end

  @doc "Whether a spec file sits at `module`'s conventional path."
  def spec_written?(context, module),
    do: Environments.file_exists?(context.environment, spec_path(module))

  defp spec_path(module), do: Fixtures.spec_file(Macro.underscore(module))
end
