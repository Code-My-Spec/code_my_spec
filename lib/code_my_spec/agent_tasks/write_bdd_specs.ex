defmodule CodeMySpec.AgentTasks.WriteBddSpecs do
  @moduledoc """
  Generate BDD specification files for a story whose three-amigos session
  is complete but whose specs haven't been written yet.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/write_bdd_specs.spec.md`.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.ContentCheck
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
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
  # Evaluate — file exists, parses, compiles, uses Spex.Case, has scenarios
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
          "Story #{story_id} was not found in this project. " <>
            "Check the id with `list_stories` (the story may have been deleted, or you're " <>
            "scoped to the wrong project)."}}

      story ->
        {:ok, story}
    end
  end

  defp resolve_story(_scope, _task) do
    {:error,
     {:story_not_specified,
      "The bdd_specs_exist task was started without a story_id. " <>
        "Call `start_task` with `entity_type: \"story\"` and `entity_id: <story_id>`."}}
  end

  defp get_story_component(_scope, %{component_id: nil} = story) do
    Logger.warning("[WriteBddSpecs] Story #{story.id} (#{story.title}) has no component linked")

    {:error,
     {:component_not_linked,
      "Story #{story.id} (#{story.title}) has no surface component linked, so the BDD spec " <>
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
        Logger.warning("[WriteBddSpecs] Story #{story.id} component #{component_id} not found")

        {:error,
         {:component_not_found,
          "Story #{story.id} is linked to component #{component_id} but no such component exists. " <>
            "The component may have been deleted; re-link the story via `set_story_component`."}}

      component ->
        {:ok, component}
    end
  end

  defp get_story_component(_scope, story) do
    Logger.warning("[WriteBddSpecs] Story #{inspect(story.id)} has no component_id field")

    {:error,
     {:component_not_linked,
      "Story #{inspect(story.id)} payload has no component_id field. " <>
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
        knowledge_section(),
        component_context_section(env, component),
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

    **Story ID**: #{story.id}
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

  defp knowledge_section do
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

    - `four_surfaces_quick_reference.md` — the four interaction surfaces
      in this codebase (MCP tool, HTTP, LiveView, filesystem) with
      one-line "I'm testing X → use surface Y" table and 30-second
      skeletons. **Read second.**
    - `surfaces.md` — canonical skeletons per surface, deeper detail.
    - `cassettes.md` — project-specific cassette conventions.\
    """
  end

  # Surfaces the component's source location and @moduledoc so the
  # spec-writer can see the real public interface rather than grepping
  # blind.
  defp component_context_section(env, %{module_name: module_name}) do
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

        _ ->
          stub_framing(inferred_path_hint(module_name))
      end

    """
    ## Component under test

    #{body}\
    """
  end

  # "Open the file to see the public API" is bad advice when there is no
  # public API — a component created by `create_component` is a stub, and the
  # specs about to be written are what define its interface. An agent told to
  # go read it opens an empty module, learns nothing, and has to work out on
  # its own that the instruction did not apply.
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

  # A module with no function definitions. `defstruct`/`use`/`alias` alone
  # still count as a stub — none of them give a spec-writer a surface to
  # drive. Deliberately textual: this runs against a file read through the
  # environment, and parsing it to decide how to phrase a prompt would buy
  # precision nobody needs.
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

  # Component-type-aware hint that routes the agent to the right section
  # of the project's four_surfaces doc. Avoids inlining per-type skeletons
  # — those live in the knowledge corpus already.
  defp surface_hint_section(component) do
    hint = surface_hint(component.type)

    """
    ## Likely surface for this component

    This component is a **#{component.type}**. The most likely surface is
    **#{hint}**.

    Pick by what the user (engineer or agent) would actually do, not by
    component type alone — see
    `.code_my_spec/knowledge/bdd/spex/four_surfaces_quick_reference.md`
    for the full decision table and the 30-second skeleton.\
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

        """
        ### Criterion #{criterion.id}: #{criterion.description}

        **Expected file path**: `#{spec_path}`\
        #{criterion_surface_line(criterion)}\
        """
      end)

    """
    ## Acceptance criteria

    #{sections}\
    """
  end

  # The scenario already said which surface it drives — "calls
  # list_qa_attempts", "navigates to the story page", "writes result.md" — so
  # read it off the `when_` step instead of asking the agent to re-derive it.
  #
  # This is per criterion on purpose. A story's criteria routinely span
  # surfaces (an MCP tool and the LiveView that shows its result), which is
  # exactly the case one sentence above the list cannot describe, and the case
  # where the component-type hint degrades to "depends".
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
  # Returns nil rather than guessing. A wrong surface is worse than none here,
  # because the agent has no reason to doubt it and will write the whole spec
  # against it.
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
    2. Module name under the `#{spex_module}` namespace.
    3. `use #{spex_module}.Case` (NOT `<App>Web.ConnCase` directly —
       the case template wires up SexySpex + ConnTest + LiveViewTest +
       DB sandbox).
    4. Drive the real interaction surface from `given_` / `when_` /
       `then_` steps. Never call context functions or `Repo` directly.
       Never read the DB from `then_`.
    5. Run `mix compile` to verify.
    6. **Stop and wait for validation** before starting the next spec.\
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
    ambiguous, **stop and flag it** rather than fudging the spec to fit.\
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

  # The prompt describes the project's source tree, so every probe in it has to
  # be asked of the machine holding that tree. Built against cwd, these sections
  # silently came back empty on a sprite — the spec-writer was told the component
  # had no @moduledoc and no sibling specs, which is a plausible-looking answer
  # rather than a visible failure.
  defp environment(%{environment: %Environment{} = env}), do: env

  defp environment(scope) do
    case Map.get(scope, :cwd) do
      cwd when is_binary(cwd) -> Environment.new(:local, cwd)
      _ -> nil
    end
  end

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

  defp validate_story_specs(scope, story) do
    criteria = story.criteria || []
    check = spec_checker(scope)

    errors =
      criteria
      |> Enum.map(fn criterion ->
        spec_path = BddSpecs.spec_file_path(story, criterion)
        {criterion, spec_path, check.(spec_path)}
      end)
      |> Enum.reject(fn {_, _, result} -> result == :ok end)
      |> Enum.map(fn {criterion, spec_path, {:error, reason}} ->
        "Criterion #{criterion.id} (#{criterion.description}): #{ContentCheck.describe(reason, spec_path)}\n  Expected: `#{spec_path}`"
      end)

    if Enum.empty?(errors) do
      {:ok, :valid}
    else
      {:ok, :invalid, "Spec issues:\n\n#{Enum.join(errors, "\n\n")}"}
    end
  end

  # Read the disk when there is one; otherwise read what the harness reported.
  #
  # There is no third option. A light harness's server has no working copy, and
  # the version of this that only knew how to read a disk answered "Spec file
  # not found" for every criterion — six of them, in a stop no edit could clear,
  # while `bdd_specs_exist` read the harness's file report in the same second
  # and correctly reported the same specs present. Two halves of one system
  # disagreeing about one fact, because only one of them was looking.
  defp spec_checker(%{environment: nil} = scope), do: &from_file_report(scope, &1)
  defp spec_checker(%{environment: env}), do: &validate_single_spec(env, &1)

  # The manifest is the whole truth — a path absent from it is a deletion, not
  # an omission — so no row here really is "not found", and says so.
  defp from_file_report(scope, spec_path) do
    case Files.get_by_path(scope, spec_path) do
      nil -> {:error, :file_not_found}
      %{valid: true} -> :ok
      %{valid: false} = file -> {:error, reported_reason(file)}
      # Present, but this harness sent no verdict for it — an older scanner that
      # does not check spex content. Existence is all that is known, and this
      # must not be dressed up as either a pass or a failure.
      %{valid: nil} -> {:error, :no_verdict}
    end
  end

  defp reported_reason(%{validation_errors: %{"reason" => reason}}) when is_binary(reason),
    do: reason

  defp reported_reason(%{validation_errors: errors}) when is_map(errors) and map_size(errors) > 0,
    do: inspect(errors)

  defp reported_reason(_file), do: "the harness reported this spec invalid without saying why"

  defp validate_single_spec(env, spec_path) do
    case Environments.read_file(env, spec_path) do
      {:ok, content} ->
        ContentCheck.check(content, spec_path)

      # Not the same as absence, and collapsing them is what made this
      # unresolvable. A light harness's server holds no working copy, so this
      # read cannot succeed for any file — and every criterion came back "Spec
      # file not found" for specs that were on the agent's disk, in a stop no
      # edit could clear.
      {:error, :no_environment} ->
        {:error, :no_environment}

      _ ->
        {:error, :file_not_found}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp derive_app_name(scope) do
    case scope.environment && Environments.read_file(scope.environment, "mix.exs") do
      {:ok, content} -> extract_app_name(content)
      _ -> "my_app"
    end
  end

  defp extract_app_name(content) do
    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> name
      _ -> "my_app"
    end
  end

  defp camelize(name) do
    name |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end
end
