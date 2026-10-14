defmodule CodeMySpec.AgentTasks.WriteBddSpecs do
  @moduledoc """
  Generate BDD specification files for a story whose three-amigos session
  is complete but whose specs haven't been written yet.

  The evaluator takes the `bdd_specs_exist` requirement's own verdict from the
  harness's file records, so the task and the requirement cannot disagree.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Stories

  require Logger

  @spex_dir "test/spex"

  def analyzers, do: [:spex_stale]

  # ============================================================================
  # dispatch — relevance signal for the requirement graph
  # ============================================================================

  def dispatch(_node) do
    "Write BDD spec files (`*_spex.exs`) for a story's acceptance criteria, " <>
      "one file per criterion, driving the real interaction surface from " <>
      "Given/When/Then steps. Use when a story has rules and scenarios " <>
      "(three-amigos complete) but no spec files yet."
  end

  # ============================================================================
  # Command — slim prompt that points at framework + project BDD knowledge
  # ============================================================================

  # Retiring a criterion is product's; this is the coder's path to it.
  @obsolete_criterion "If a criterion is obsolete or wrong, don't delete its spec; file an " <>
                        "app issue on the story (`create_issue`) naming the criterion and why; " <>
                        "product retires or rewrites it."

  @doc "What a coder does with a criterion it thinks should go."
  def obsolete_criterion, do: @obsolete_criterion

  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, task) do
    with {:ok, story} <- resolve_story(scope, task),
         {:ok, component} <- get_story_component(scope, story) do
      app_name = derive_app_name(scope)
      spex_module = "#{camelize(app_name)}Spex"

      prompt = build_prompt(scope, story, component, app_name, spex_module)
      {:ok, prompt}
    end
  end

  # ============================================================================
  # Evaluate — every criterion covered by a valid spec in the file records
  # ============================================================================

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, task) do
    with {:ok, story} <- resolve_story(scope, task) do
      validate_story_specs(scope, story)
    end
  end

  # ============================================================================
  # Story / Component Resolution
  # ============================================================================

  defp resolve_story(scope, %{story_id: story_id}) when not is_nil(story_id) do
    case Stories.get_story(scope, story_id) do
      nil ->
        {:error,
         {:story_not_found,
          "This task's story was not found in this project. " <>
            "Check the story number with `list_stories` (the story may have been retired, or you're " <>
            "scoped to the wrong project)."}}

      story ->
        {:ok, story}
    end
  end

  defp resolve_story(_scope, _task) do
    {:error,
     {:story_not_specified,
      "The bdd_specs_exist task was started without a story. " <>
        "Call `start_task` with `entity_type: \"story\"` and `entity_id: <story_number>`."}}
  end

  defp get_story_component(_scope, %{component_id: nil} = story) do
    Logger.warning(
      "[WriteBddSpecs] Story #{story.number} (#{story.title}) has no component linked"
    )

    {:error,
     {:component_not_linked,
      "Story #{story.number} (#{story.title}) has no surface component linked, so the BDD spec " <>
        "writer can't tell which surface to drive in Given/When/Then steps.\n\n" <>
        "Resolutions:\n" <>
        "  - If the implementing component already exists in the architecture, call " <>
        "`set_story_component` with its module name.\n" <>
        "  - If the story introduces a NEW context that doesn't have a component yet, " <>
        "call `create_component` first (name + module_name + type), then `set_story_component`. " <>
        "Children can be added later; a context with no children is a valid state.\n" <>
        "  - Or run the project-level `architecture_designed` task — it surfaces every unlinked " <>
        "story along with diagnostic context."}}
  end

  defp get_story_component(scope, %{component_id: component_id} = story) do
    case Components.get_component(scope, component_id) do
      nil ->
        Logger.warning(
          "[WriteBddSpecs] Story #{story.number} component #{component_id} not found"
        )

        {:error,
         {:component_not_found,
          "Story #{story.number} is linked to component #{component_id} but no such component exists. " <>
            "The component may have been deleted; re-link the story via `set_story_component`."}}

      component ->
        {:ok, component}
    end
  end

  defp get_story_component(_scope, story) do
    Logger.warning(
      "[WriteBddSpecs] Story #{inspect(Map.get(story, :number))} has no component_id field"
    )

    {:error,
     {:component_not_linked,
      "Story #{inspect(Map.get(story, :number))} payload has no component_id field. " <>
        "Refresh the story via `get_story` or link a component via `set_story_component`."}}
  end

  # ============================================================================
  # Prompt assembly
  # ============================================================================

  defp build_prompt(scope, story, component, app_name, spex_module) do
    criteria = story.criteria || []
    env = environment(scope)

    sections =
      [
        header_section(story, component),
        mental_model_section(),
        knowledge_section(scope),
        component_context_section(scope, env, component),
        sibling_specs_section(env, story, criteria),
        surface_hint_section(component),
        criteria_section(story, criteria),
        procedure_section(spex_module),
        anti_patterns_section(),
        reference_files_section(app_name, spex_module)
      ]
      |> Enum.reject(&(&1 == nil or &1 == ""))

    Enum.join(sections, "\n\n")
  end

  defp header_section(story, component) do
    """
    # Write BDD Specs: #{story.title}

    **Story**: #{story.number}
    **Description**: #{story.description || "No description"}
    **Component**: `#{component.module_name}` (#{component.type})\
    """
  end

  defp mental_model_section do
    """
    ## What you're producing

    These are specifications of acceptance criteria, not regression tests
    of existing behavior. A scenario is a mechanical translation of the
    criterion text into Given/When/Then driving the real surface — what
    the criterion **says must be true**, not what the code happens to do
    today.

    **Failing on first run is the expected outcome.** Unsatisfied criteria
    produce red specs; the next workflow step uses that red bar to drive
    the implementation. You do **not** need the scenarios to pass for
    this task to succeed.

    **The evaluator is shape-only** — it parses, compiles, asserts
    `use *.Spex.Case`, and asserts Given/When/Then steps exist. It does
    **not** run `mix test`. Validation passing is not the same as
    scenarios passing. Encode the criterion faithfully; let the implementer
    worry about turning it green.\
    """
  end

  defp knowledge_section(scope) do
    """
    ## Required reading — both layers

    Read both knowledge layers before writing specs. **Project rules
    override framework rules where they conflict.**

    ### Framework BDD knowledge (read via the `read_knowledge` MCP tool, under `bdd/spex/`)

    - `bdd/spex/writing_a_spex.md` — file layout, module template, DSL
      syntax, step return values. **Essential — read first.**
    - `bdd/spex/philosophy.md` — what Spex is and how it differs from
      regular tests.
    - `bdd/spex/environment.md` — environment abstraction in steps.
    - `bdd/spex/boundaries.md` — what `given_` / `when_` / `then_` can and
      can't do.
    - `bdd/spex/shared_givens.md` — importing shared given blocks.
    - `bdd/spex/recording_cassettes.md` — when and how to record HTTP
      cassettes.

    ### Project BDD knowledge (`.code_my_spec/knowledge/bdd/spex/`)

    #{project_knowledge(scope)}\
    """
  end

  # What this project actually has, from the synced file records, rather than
  # file names a template guessed. Named files, not just the directory, saves
  # the agent a listing turn.
  defp project_knowledge(scope) do
    case knowledge_files(scope) do
      [] ->
        "This project has no BDD knowledge of its own yet. The framework " <>
          "layer above is the whole of it — do not go looking for project " <>
          "files, and do not assume conventions this codebase has not written " <>
          "down."

      paths ->
        listed = Enum.map_join(paths, "\n", &"    - `#{Path.basename(&1)}`")

        "Read all of these. Project rules override the framework where they " <>
          "conflict.\n\n" <> listed
    end
  end

  @knowledge_dir ".code_my_spec/knowledge/bdd/spex/"

  defp knowledge_files(scope) do
    scope
    |> Files.list_files()
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.starts_with?(&1, @knowledge_dir))
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    # A prompt is not the place to fail over a listing; naming nothing is
    # recoverable.
    _error -> []
  end

  # Surfaces the component's source location and @moduledoc so the
  # spec-writer can see the real public interface rather than grepping
  # blind.
  defp component_context_section(scope, env, %{module_name: module_name} = component) do
    path = module_path(env, module_name)

    body =
      case path && Environments.read_file(env, path) do
        {:ok, source} ->
          if stub_source?(source) do
            stub_framing(path)
          else
            """
            Source: `#{path}`

            #{extract_moduledoc(source)}\
            """
          end

        # Nothing was read: ask the file report which of two facts it is.
        _ ->
          unread_framing(scope, component, module_name)
      end

    """
    ## Component under test

    #{body}\
    """
  end

  # An empty read wants opposite advice depending on why. On a light harness
  # every read is empty, and "this is a stub, invent the API" for an implemented
  # module produces spex against a made-up interface. An implementation file
  # row means the file exists and this server cannot open it; no row means a
  # real stub.
  defp unread_framing(scope, component, module_name) do
    case implementation_files(scope, component) do
      [] ->
        stub_framing(inferred_path_hint(module_name))

      [%{path: path} | _] ->
        """
        Source: `#{path}` — present in the project, but this server holds no
        working copy and cannot show you its contents.

        **Do not treat this as a stub.** Open the file and read the public API
        before writing spex against it; inventing an interface when one already
        exists produces spex that fail for reasons that look like missing
        implementation.\
        """
    end
  end

  defp implementation_files(scope, %{id: id}) when not is_nil(id) do
    scope
    |> Files.list_component_files(id)
    |> Enum.filter(&(&1.role == :implementation))
  end

  defp implementation_files(_scope, _component), do: []

  # A stub has no public API to read; the specs about to be written define it.
  defp stub_framing(path) do
    """
    Source: `#{path}` — **this component is a stub.** There is no
    implementation to read yet, and that is the normal starting point here
    rather than something missing.

    Write the spex against the surfaces named in the scenario bodies below.
    They *are* the contract: the implementation gets built to satisfy them,
    so anything you invent here becomes the public API by default. Do not
    infer an interface from the empty module.\
    """
  end

  # A module with no function definitions (`defstruct`/`use`/`alias` alone
  # give no surface to drive). Textual on purpose: precision is not needed to
  # phrase a prompt.
  defp stub_source?(source) do
    not Regex.match?(~r/^\s{2,}(def|defdelegate|defmacro)\s/m, source)
  end

  # If other specs in the same story already exist, point at one so the
  # author can copy the established pattern (setup blocks, fixture paths,
  # shared givens, module namespace) rather than reinventing.
  defp sibling_specs_section(env, story, criteria) do
    dir = story_spec_dir(story, criteria)

    case dir && list_existing_specs(env, dir) do
      [_ | _] = existing ->
        bullets = Enum.map_join(existing, "\n", &"- `#{&1}`")

        """
        ## Sibling specs in this story

        Other criteria in this story have already been written. Read at
        least one end-to-end as a template for shared setup, fixture
        paths, case template, and given usage:

        #{bullets}\
        """

      _ ->
        nil
    end
  end

  # Component-type hint for the likely surface; the project's BDD knowledge
  # carries the real decision table.
  defp surface_hint_section(component) do
    hint = surface_hint(component.type)

    """
    ## Likely surface for this component

    This component is a **#{component.type}**. The most likely surface is
    **#{hint}**.

    Pick by what the user (engineer or agent) would actually do, not by
    component type alone — the project BDD knowledge listed above carries
    this codebase's decision table, where it has one.\
    """
  end

  defp surface_hint("liveview"), do: "LiveView (a user interacting with a page)"
  defp surface_hint("liveview_component"), do: "LiveView (a user interacting with a page)"
  defp surface_hint("live_context"), do: "LiveView (a user interacting with a page)"
  defp surface_hint("controller"), do: "HTTP (a controller endpoint, possibly with cassette)"

  defp surface_hint(_),
    do: "MCP tool or HTTP — depends on whether an agent or a hook drives the criterion"

  defp criteria_section(story, criteria) do
    sections =
      Enum.map_join(criteria, "\n\n", fn criterion ->
        spec_path = BddSpecs.spec_file_path(story, criterion)

        # "Suggested", not "expected": the `criterion:` option binds the file,
        # not its path, and renaming an adopted spec to match a derived slug
        # breaks it.
        """
        ### Criterion #{criterion.number}: #{criterion.description}
        #{criterion_body(criterion)}
        **Names it**: `spex "…", criterion: #{criterion.number} do` — this is
        what binds the file to the criterion.
        **Suggested file path**: `#{spec_path}`
        The path is cosmetic; any file under `test/spex/` works.\
        #{criterion_surface_line(criterion)}\
        """
      end)

    """
    ## Acceptance criteria

    #{sections}\
    """
  end

  # The scenario body, inline: for a stub component it is the contract, and it
  # is short and already loaded.
  defp criterion_body(%{body: body}) when is_binary(body) do
    body |> String.trim() |> fenced()
  end

  defp criterion_body(_criterion), do: fenced("")

  defp fenced(""), do: no_scenario()
  defp fenced(body), do: "\n```gherkin\n" <> body <> "\n```\n"

  # A missing (or whitespace-only) body is said outright, so the agent does not
  # assume the prompt omitted it.
  defp no_scenario,
    do: "\n_No scenario recorded for this criterion — it is a title only._\n"

  # The surface read off the scenario's `when_` steps, per criterion, since a
  # story's criteria often span surfaces.
  defp criterion_surface_line(%{body: body}) when is_binary(body) do
    case infer_surface(when_steps(body)) do
      nil -> ""
      surface -> "\n\n**Surface** (from the `When` step): #{surface}"
    end
  end

  defp criterion_surface_line(_criterion), do: ""

  defp when_steps(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\s*(when_?|and)\b/i, &1))
    |> Enum.join(" ")
    |> String.downcase()
  end

  # First match wins, so the order is the ranking: a phrase that names a page
  # or a file is describing that surface even if it also says "calls". The
  # bare-verb MCP pattern is last among the specific ones for that reason.
  #
  # Returns nil rather than guessing: the agent has no reason to doubt a wrong
  # surface.
  defp infer_surface(text) do
    Enum.find_value(
      [
        {~r/\b(navigat\w*|visit\w*|clicks?|renders?|live_?view|page|button|form)\b/, "LiveView"},
        {~r/\b(writes?|edits?|deletes?|creates?)\b[^\n]*\.(md|ex|exs|json|ya?ml)\b/,
         "filesystem"},
        {~r/\b(hooks?|manifest|scans?)\b/, "HTTP (hook endpoint)"},
        {~r/\b(endpoints?|controllers?|https?|curl|webhooks?|request)\b/, "HTTP"},
        {~r/\b(mcp|tools?|get_next_requirement|start_task)\b/, "MCP tool"},
        {~r/\bcalls?\s+[a-z][a-z0-9_]*\b/, "MCP tool"}
      ],
      fn {pattern, surface} -> Regex.match?(pattern, text) && surface end
    )
  end

  defp procedure_section(spex_module) do
    """
    ## Procedure

    Write **one** spec file per criterion, then **stop** for validation.
    The evaluator runs after each session — it checks file existence,
    parses, compiles via `Code.string_to_quoted/2`, asserts `use` of
    `#{spex_module}.Case`, and asserts at least one scenario with
    Given/When/Then steps. If validation fails, next-session feedback
    tells you exactly what's wrong.

    For each criterion:

    1. Create the spec file at the path shown above.
    2. Put `criterion: <number>` on the `spex` call, as shown above. A spec
       that names no criterion is invalid and covers nothing.
    3. Module name under the `#{spex_module}` namespace.
    4. `use #{spex_module}.Case` (NOT `<App>Web.ConnCase` directly —
       the case template wires up SexySpex + ConnTest + LiveViewTest +
       DB sandbox).
    5. Drive the real interaction surface from `given_` / `when_` /
       `then_` steps. Never call context functions or `Repo` directly.
       Never read the DB from `then_`.
    6. Run `mix compile` to verify.
    7. **Stop and wait for validation** before starting the next spec.\
    """
  end

  defp anti_patterns_section do
    """
    ## Do not

    Failure modes that turn the spec into a self-fulfilling pass instead
    of a faithful encoding of the criterion:

    - **Soften the assertion to match current behavior.** If the criterion
      says 401, assert 401 — not `assert conn.status in [200, 401]`
      because the code returns 200 today.
    - **Fabricate rules or criteria.** Only write scenarios for the rules
      and criteria already on the story. If something feels
      under-specified, surface the question — don't invent a rule.
    - **`@tag :pending`, `@tag :skip`, or comment out scenarios that
      fail.** A failing scenario is the point. Tagging it out hides the
      signal the implementer needs.
    - **Pre-seed in `given_` what the SUT should produce.** If the
      criterion says "creating a Foo also creates a Bar", `when_`
      triggers the action and `then_` asserts both side effects.
      Don't `given_` the Bar into existence.
    - **Stub or mock the surface under test.** Drive the real LiveView /
      HTTP / MCP tool. Mocks make the spec a tautology.
    - **Read the implementation and write its current behavior as the
      expectation.** Read the criterion; write the criterion. If the
      code doesn't match, that's information — surface it through a
      failing spec.

    If a criterion is genuinely untestable, contradicts another, or is
    ambiguous, **stop and flag it** rather than fudging the spec to fit.

    #{obsolete_criterion()}\
    """
  end

  defp reference_files_section(app_name, spex_module) do
    """
    ## Reference files

    - Case template: `test/support/#{app_name}_spex_case.ex` — defines
      `#{spex_module}.Case`.
    - Boundary: `#{@spex_dir}/#{app_name}_spex.ex`.
    - Shared givens: `test/support/shared_givens.ex`.\
    """
  end

  # ============================================================================
  # Component source helpers
  # ============================================================================

  defp module_path(env, module_name) when is_binary(module_name) do
    relative =
      module_name
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    candidates = ["lib/#{relative}.ex", "#{relative}.ex"]
    Enum.find(candidates, &Environments.file_exists?(env, &1))
  end

  defp module_path(_env, _), do: nil

  # Every probe of the source tree is asked of the machine holding it, never
  # this server's cwd.
  defp environment(scope), do: CodeMySpec.AgentTasks.environment(scope)

  defp inferred_path_hint(module_name) when is_binary(module_name) do
    relative =
      module_name
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    "lib/#{relative}.ex"
  end

  defp inferred_path_hint(_), do: "lib/<path>.ex"

  defp extract_moduledoc(source) do
    case Regex.run(~r/@moduledoc\s+"""\n(.*?)\n\s*"""/s, source) do
      [_, doc] ->
        trimmed = String.trim(doc)
        "### Module documentation\n\n#{trimmed}"

      _ ->
        "(No @moduledoc; open the file to understand the public API.)"
    end
  end

  defp story_spec_dir(story, [first | _]) do
    Path.dirname(BddSpecs.spec_file_path(story, first))
  end

  defp story_spec_dir(_story, _), do: nil

  defp list_existing_specs(env, dir) do
    case Environments.list_directory(env, dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, "_spex.exs"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  # ============================================================================
  # Validation (evaluate)
  # ============================================================================

  # The requirement's own verdict, from the same function and the same rows,
  # so the task cannot pass while `bdd_specs_exist` stays unsatisfied.
  defp validate_story_specs(scope, story) do
    criteria = story.criteria || []
    specs = scope |> Files.list_files() |> Enum.filter(&(&1.role == :bdd_spec))

    case RequirementCalculator.bdd_specs_covered(criteria, specs, :bdd_spec) do
      {true, _details} ->
        {:ok, :valid}

      {false, %{missing_criteria: missing}} ->
        errors =
          criteria
          |> Enum.filter(&(&1.number in missing))
          |> Enum.map(&uncovered(&1, specs))

        {:ok, :invalid, "Spec issues:\n\n#{Enum.join(errors, "\n\n")}#{looked_in(scope)}"}

      {false, %{reason: reason}} ->
        {:ok, :invalid, "Spec issues:\n\n#{reason}#{looked_in(scope)}"}
    end
  end

  # Where it looked, so a refusal can be checked against the rows in one step;
  # a "not found" that names no scope hides scoping defects.
  defp looked_in(scope) do
    "\n\nLooked in: project #{inspect(scope.active_project_id)}" <>
      ", working copy #{inspect(scope.active_working_copy_id)}"
  end

  # Why a criterion is uncovered: the reason on a spec that names it and could
  # not bind, or that nothing names it.
  defp uncovered(criterion, specs) do
    naming =
      Enum.filter(specs, fn spec ->
        spec.criterion_number == criterion.number
      end)

    why =
      case naming do
        [] ->
          "No valid spec names it. Put `criterion: #{criterion.number}` on a `spex` call."

        files ->
          Enum.map_join(files, "\n  ", &"`#{&1.path}`: #{reported_reason(&1)}")
      end

    "Criterion #{criterion.number} (#{criterion.description}): #{why}"
  end

  defp reported_reason(%{validation_errors: %{"reason" => reason}}) when is_binary(reason),
    do: reason

  defp reported_reason(_file), do: "the harness reported this spec invalid without saying why"

  # ============================================================================
  # Helpers
  # ============================================================================

  # `mix.exs` first, the app name the project compiles under; otherwise the
  # project's module name. `my_app` is the last resort: placeholders in a prompt
  # read as real instructions.
  defp derive_app_name(scope) do
    env = CodeMySpec.AgentTasks.environment(scope)

    case env && Environments.read_file(env, "mix.exs") do
      {:ok, content} -> extract_app_name(content, scope)
      _ -> app_name_from_project(scope)
    end
  end

  defp app_name_from_project(%{active_project: %{module_name: module_name}})
       when is_binary(module_name) and module_name != "",
       do: Macro.underscore(module_name)

  defp app_name_from_project(_scope), do: "my_app"

  # A `mix.exs` with no `app:` falls back the same way.
  defp extract_app_name(content, scope) do
    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> name
      _ -> app_name_from_project(scope)
    end
  end

  defp camelize(name) do
    name |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end
end
