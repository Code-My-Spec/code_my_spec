defmodule CodeMySpecSpex.GraphContentFixtures do
  @moduledoc """
  Spec and impl file content for graph topology BDD specs.

  Sync derives the requirement graph from spec metadata: parent/child
  comes from module nesting (`Foo.Bar` → parent `Foo`), dependencies
  come from the `## Dependencies` section. So a topology fixture is
  just a set of well-formed spec files written into the in-memory
  environment — no MCP `CreateDependency` calls needed.

  Stories 561, 562, 671 depend on this module to assemble multi-context
  projects with cross-context deps, parent/child trees, and orphans.

  ## Validity guarantee

  Every spec emitted by this module passes the document validator
  (`Documents.create_dynamic_document/2`) for its declared type. The
  required-section coverage for each type is defined in
  `CodeMySpec.Documents.Registry`:

  - context / coordination_context (`context_spec`): functions,
    dependencies, components
  - live_context (`live_context_spec`): liveviews, components,
    dependencies
  - schema (`schema`): fields
  - liveview (`liveview`): route, user interactions, dependencies,
    design
  - liveview_component (`liveview_component`): assigns, design
  - everything else (`spec`): functions, dependencies

  This validity is necessary so that `spec_valid` requirements are
  satisfied upstream, allowing downstream child requirements to
  evaluate honestly under rule 2 (`satisfied = own_check AND
  prereqs_all_satisfied`). A thin/invalid spec would clamp every
  child below it.
  """

  @doc """
  Spec content for a context-type component.

  ## Options

  - `:type` — one of `"context"`, `"coordination_context"`,
    `"live_context"`. Defaults to `"context"`.
  - `:dependencies` — list of module names this context depends on.
    Defaults to `[]` (renders as `- None`).
  - `:children` — list of `%{module: ..., type: ...}` maps describing
    child components. Used only for the `## Components` section
    rendering; sync still derives the actual parent/child relation
    from module nesting.
  - `:description` — free-text intro. Defaults to a placeholder.
  """
  @spec context_spec(String.t(), keyword()) :: String.t()
  def context_spec(module_name, opts \\ []) do
    type = Keyword.get(opts, :type, "context")

    case type do
      "live_context" -> live_context_spec_content(module_name, opts)
      _ -> context_spec_content(module_name, type, opts)
    end
  end

  @doc """
  Spec content for a leaf component. Routed to a type-specific
  template based on `opts[:type]`.

  ## Options

  - `:type` — `"schema"`, `"repository"`, `"service"`, `"behaviour"`,
    `"json"`, `"controller"`. Defaults to `"schema"`.
  - `:dependencies` — list of module names. Defaults to `[]`.
  - `:description` — free-text intro. Defaults to a placeholder.
  """
  @spec child_spec(String.t(), keyword()) :: String.t()
  def child_spec(module_name, opts \\ []) do
    type = Keyword.get(opts, :type, "schema")

    case type do
      "schema" -> schema_spec_content(module_name, opts)
      "json" -> json_spec_content(module_name, opts)
      _ -> default_spec_content(module_name, type, opts)
    end
  end

  @doc """
  Spec content for a LiveView surface component.
  """
  @spec liveview_spec(String.t(), keyword()) :: String.t()
  def liveview_spec(module_name, opts \\ []) do
    type = Keyword.get(opts, :type, "liveview")

    case type do
      "liveview_component" -> liveview_component_spec_content(module_name, opts)
      _ -> liveview_spec_content(module_name, opts)
    end
  end

  @doc """
  Stub implementation file content. The implementation_file
  requirement only checks file existence — content correctness is
  out of scope for graph topology fixtures.
  """
  @spec impl_file(String.t()) :: String.t()
  def impl_file(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc false
    end
    """
  end

  @doc """
  Canonical spec path for a module.
  """
  @spec spec_path(String.t()) :: String.t()
  def spec_path(module_name) do
    relative = module_name |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)
    ".code_my_spec/spec/#{relative}.spec.md"
  end

  @doc """
  Canonical implementation path for a module.
  """
  @spec impl_path(String.t()) :: String.t()
  def impl_path(module_name) do
    relative = module_name |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)
    "lib/#{relative}.ex"
  end

  # -- Content templates --

  defp context_spec_content(module_name, type, opts) do
    deps = Keyword.get(opts, :dependencies, [])
    description = Keyword.get(opts, :description, "Test #{type} for graph topology specs.")
    children = Keyword.get(opts, :children, [])

    """
    # #{module_name}

    ## Type

    #{type}

    #{description}

    ## Functions

    ### noop/0

    Placeholder function for graph topology fixtures.

    ```elixir
    @spec noop() :: :ok
    ```

    **Process**:
    1. Returns `:ok`

    **Test Assertions**:
    - returns ok

    ## Dependencies

    #{render_module_list(deps)}

    ## Components

    #{render_components(children, module_name)}
    """
  end

  defp live_context_spec_content(module_name, opts) do
    deps = Keyword.get(opts, :dependencies, [])
    description = Keyword.get(opts, :description, "Test live_context for graph topology specs.")
    liveviews = Keyword.get(opts, :liveviews, [])
    components = Keyword.get(opts, :components, [])

    """
    # #{module_name}

    ## Type

    live_context

    #{description}

    ## LiveViews

    #{render_liveviews(liveviews, module_name)}

    ## Components

    #{render_live_components(components, module_name)}

    ## Dependencies

    #{render_module_list(deps)}
    """
  end

  defp schema_spec_content(module_name, opts) do
    deps = Keyword.get(opts, :dependencies, [])
    description = Keyword.get(opts, :description, "Test schema for graph topology specs.")

    """
    # #{module_name}

    ## Type

    schema

    #{description}

    ## Fields

    | Field | Type    | Required   | Description       | Constraints    |
    | ----- | ------- | ---------- | ----------------- | -------------- |
    | id    | integer | Yes (auto) | Primary key       | Auto-generated |
    | name  | string  | Yes        | Test display name | Min: 1, Max: 255 |

    ## Dependencies

    #{render_module_list(deps)}
    """
  end

  defp default_spec_content(module_name, type, opts) do
    deps = Keyword.get(opts, :dependencies, [])
    description = Keyword.get(opts, :description, "Test #{type} for graph topology specs.")

    """
    # #{module_name}

    ## Type

    #{type}

    #{description}

    ## Functions

    ### noop/0

    Placeholder function for graph topology fixtures.

    ```elixir
    @spec noop() :: :ok
    ```

    **Process**:
    1. Returns `:ok`

    **Test Assertions**:
    - returns ok

    ## Dependencies

    #{render_module_list(deps)}
    """
  end

  defp liveview_spec_content(module_name, opts) do
    deps = Keyword.get(opts, :dependencies, [])
    description = Keyword.get(opts, :description, "Test liveview for graph topology specs.")

    """
    # #{module_name}

    ## Type

    liveview

    #{description}

    ## Route

    `/test/#{Macro.underscore(module_name |> String.split(".") |> List.last())}`

    ## User Interactions

    - **phx-click="noop"**: Placeholder no-op event for graph topology fixtures.

    ## Dependencies

    #{render_module_list(deps)}

    ## Design

    Layout: Single-column placeholder page.
    Components: .card, .btn-primary
    Responsive: Stacks on mobile.
    """
  end

  defp liveview_component_spec_content(module_name, opts) do
    deps = Keyword.get(opts, :dependencies, [])
    description = Keyword.get(opts, :description, "Test liveview_component for graph topology specs.")

    """
    # #{module_name}

    ## Type

    liveview_component

    #{description}

    ## Assigns

    | Assign | Type | Required | Description                    |
    | ------ | ---- | -------- | ------------------------------ |
    | id     | any  | Yes      | Component instance identifier  |
    | data   | map  | Yes      | Placeholder data for fixtures  |

    ## Design

    Layout: Single-column placeholder component.
    Components: .card

    ## Dependencies

    #{render_module_list(deps)}
    """
  end

  defp json_spec_content(module_name, _opts) do
    """
    # #{module_name}

    ## Type

    json

    Test json view for graph topology specs.

    ## Functions

    ### render/2

    Placeholder render for graph topology fixtures.

    ```elixir
    @spec render(String.t(), map()) :: map()
    ```

    **Process**:
    1. Returns the assigns map unchanged.

    **Test Assertions**:
    - returns assigns map
    """
  end

  # -- Section renderers --

  defp render_module_list([]), do: "- None"

  defp render_module_list(modules) when is_list(modules) do
    Enum.map_join(modules, "\n", &"- #{&1}")
  end

  defp render_components([], parent_module) do
    """
    ### #{parent_module}.Placeholder

    Placeholder child component for graph topology fixtures.
    """
  end

  defp render_components(children, _parent_module) do
    Enum.map_join(children, "\n\n", fn %{module: mod} = child ->
      desc = Map.get(child, :description, "Child component for graph topology fixtures.")

      """
      ### #{mod}

      #{desc}
      """
    end)
  end

  defp render_liveviews([], parent_module) do
    """
    ### #{parent_module}.PlaceholderLive

    - **Route:** `/placeholder`
    - **Description:** Placeholder LiveView for graph topology fixtures.
    """
  end

  defp render_liveviews(liveviews, _parent_module) do
    Enum.map_join(liveviews, "\n\n", fn %{module: mod} = lv ->
      route = Map.get(lv, :route, "/placeholder")
      desc = Map.get(lv, :description, "Placeholder LiveView for graph topology fixtures.")

      """
      ### #{mod}

      - **Route:** `#{route}`
      - **Description:** #{desc}
      """
    end)
  end

  defp render_live_components([], parent_module) do
    """
    ### #{parent_module}.PlaceholderComponent

    Placeholder LiveComponent for graph topology fixtures.
    """
  end

  defp render_live_components(components, _parent_module) do
    Enum.map_join(components, "\n\n", fn %{module: mod} = comp ->
      desc = Map.get(comp, :description, "Placeholder LiveComponent for graph topology fixtures.")

      """
      ### #{mod}

      #{desc}
      """
    end)
  end
end
