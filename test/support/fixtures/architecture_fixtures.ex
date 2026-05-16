defmodule CodeMySpec.ArchitectureFixtures do
  @moduledoc """
  Test helpers for architecture-level setup.

  Two responsibilities:

    1. **Proposal markdown templates** — composable strings that match the
       parser's expectations. Use these instead of inlining proposal markdown
       in each spec; tests stay aligned when the proposal format evolves.

    2. **Bringing components into existence through the real flow** —
       `with_executed_proposal/3` writes the proposal to the environment and
       runs `Proposal.execute/3`, which materialises components into the DB
       and writes spec stubs. Tests that need pre-existing components should
       use this rather than fixturing DB rows directly, so the setup mirrors
       the production path the agent travels.
  """

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths

  @doc """
  Returns proposal markdown declaring a single context component plus the
  empty `Surface Components` and `Dependencies` sections the parser
  requires. Use this when a test needs a pre-existing context without any
  surface or dependency state.
  """
  @spec proposal_with_context(String.t(), String.t(), String.t()) :: String.t()
  def proposal_with_context(app, name, description) do
    """
    # Architecture Proposal

    ## Surface Components

    ## Contexts

    ### #{app}.#{name}

    - **Type:** context
    - **Description:** #{description}

    ## Dependencies
    """
  end

  @doc """
  Returns proposal markdown declaring a surface component plus a context with
  a dependency between them. Optionally maps a story to the surface component.

  Options:
    * `:app` — application module name (default `"MyApp"`)
    * `:surface_name` — surface component suffix (default `"FeatureLive"`)
    * `:surface_type` — `"liveview"` or `"controller"` (default `"liveview"`)
    * `:surface_description` — surface component description
    * `:context_name` — context name suffix (default `"Feature"`)
    * `:context_description` — context description
    * `:story_id` — optional story id to map onto the surface component
  """
  @spec proposal_with_surface_and_context(keyword()) :: String.t()
  def proposal_with_surface_and_context(opts \\ []) do
    app = Keyword.get(opts, :app, "MyApp")
    surface = Keyword.get(opts, :surface_name, "FeatureLive")
    surface_type = Keyword.get(opts, :surface_type, "liveview")
    surface_desc = Keyword.get(opts, :surface_description, "Feature LiveView")
    context = Keyword.get(opts, :context_name, "Feature")
    context_desc = Keyword.get(opts, :context_description, "Feature domain")
    story_id = Keyword.get(opts, :story_id)

    story_line = if story_id, do: "\n- **Stories:** #{story_id}", else: ""

    """
    # Architecture Proposal

    ## Surface Components

    ### #{app}Web.#{surface}

    - **Type:** #{surface_type}
    - **Description:** #{surface_desc}#{story_line}

    ## Contexts

    ### #{app}.#{context}

    - **Type:** context
    - **Description:** #{context_desc}

    ## Dependencies

    - #{app}Web.#{surface} -> #{app}.#{context}
    """
  end

  @doc """
  Writes proposal markdown to the conventional `proposal.md` path through
  the environment. Returns `:ok` or raises on failure.
  """
  @spec with_proposal(map(), String.t()) :: :ok
  def with_proposal(env, content) do
    :ok = Environments.write_file(env, Paths.proposal_path(), content)
  end

  @doc """
  Writes the proposal AND runs `Proposal.execute/3`, which creates DB rows
  and stub spec files for every component declared in the proposal — the
  same path the architecture flow uses in production.

  Use this in `given_` steps to set up pre-existing components without
  reaching into the DB via `component_fixture`.
  """
  @spec with_executed_proposal(map(), map(), String.t()) :: {:ok, map()}
  def with_executed_proposal(scope, env, content) do
    app_name = app_name_for(scope)
    working_dir = scope.cwd || (env && env.cwd) || File.cwd!()

    :ok = Environments.write_file(env, Paths.proposal_path(), content)
    {:ok, proposal} = Proposal.from_markdown(content, app_name: app_name)

    Proposal.execute(proposal, scope, env: env, working_dir: working_dir)
  end

  @doc """
  Inserts a component dependency row directly via `Components.create_dependency/2`,
  bypassing `Proposal.validate/2`. Use this when a spec needs a cyclic
  dependency in the DB — the proposal flow rejects non-schema cycles by
  design, so the architect's normal write surface can't produce them. The
  validator-under-test (`validate_dependency_graph`) still needs the cycle
  to assert against.

  Takes the source and target components (as returned by
  `with_executed_proposal/3` + `get_component_by_module_name/2`).
  """
  @spec dependency_fixture(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def dependency_fixture(scope, %{id: source_id}, %{id: target_id}) do
    alias CodeMySpec.Components

    Components.create_dependency(scope, %{
      source_component_id: source_id,
      target_component_id: target_id
    })
  end

  @doc """
  Upserts a component row directly via `Components.upsert_component/2`,
  bypassing `Proposal.validate/2`. Use this when a spec needs an
  orphaned context (no story link, no incoming/outgoing dependencies) —
  the proposal flow rejects orphan contexts unless they're typed
  `infrastructure`, and the orphan detector (`list_orphaned_contexts`)
  excludes infrastructure. The validator-under-test needs an honest
  orphan that the surface can't produce.
  """
  @spec component_fixture(map(), map()) :: map()
  def component_fixture(scope, attrs) do
    alias CodeMySpec.Components

    {:ok, component} = Components.upsert_component(scope, attrs)
    component
  end

  defp app_name_for(scope) do
    case scope.active_project do
      %{module_name: name} when is_binary(name) and name != "" -> name
      %{name: name} when is_binary(name) and name != "" -> Macro.camelize(name)
      _ -> "MyApp"
    end
  end
end
