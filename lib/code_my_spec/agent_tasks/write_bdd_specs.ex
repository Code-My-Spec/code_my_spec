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

        # Nothing was read. That is two different facts, and telling an agent
        # the wrong one is expensive in opposite directions — so ask the file
        # report before saying which.
        _ ->
          unread_framing(scope, component, module_name)
      end

    """
    ## Component under test

    #{body}\
    """
  end

  # A read that returned nothing means one of two things, and they want opposite
  # advice. On a light harness the server holds no working copy, so *every* read
  # returns nothing — and this used to answer "this component is a stub, invent
  # the API" for a 200-line implemented module. An agent that believes it writes
  # spex against an interface it made up while a working one exists, and the
  # spex then fail in ways that look like implementation gaps.
  #
  # The file report knows which it is without a disk. A row means the file is
  # there and this server simply cannot open it; no row means there is genuinely
  # nothing to read, which is the case `stub_framing/1` was written for.
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

        # "Suggested", not "expected", and it says why. A criterion that has no
        # file yet gets a path derived from its description; once a file exists
        # the criterion adopts *that* path and this line reports it back.
        #
        # Calling it "expected" reads as a requirement, and it costs a rename:
        # a spec written at a slightly different slug is already correct and
        # already adopted, and renaming it to match this line is what makes the
        # evaluator report it missing. That happened on story 967 — the
        # description held an apostrophe, the derived slug dropped it, the
        # written file kept it as an underscore, and following this line broke
        # a file that was fine.
        """
        ### Criterion #{criterion.id}: #{criterion.description}

        **Suggested file path**: `#{spec_path}`
        Any path under the story's directory works — whatever you write is
        adopted, and this line reports it back once it exists.\
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
        "Criterion #{criterion.id} (#{criterion.description}): #{ContentCheck.describe(reason, spec_path)}\n  Expected: `#{spec_path}`#{where(reason, scope)}"
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
  # Across every checkout of the project, not just the one asking.
  #
  # A spec file is a fact about the story. Whether it exists does not depend on
  # which copy you happen to be sitting in, and scoping it to the requesting one
  # made `bdd_specs_exist` gate on *have you pushed* rather than on *have you
  # written the spec*: an agent working in a worktree wrote six specs, was told
  # all six were missing, and then told they were fine — with no change to any
  # of them — because a `just refresh` had pulled them into a second checkout in
  # between. Measured on story 967.
  #
  # Deliberately unlike problems and analyzer results, which `DeployKeyOrOAuth`
  # narrows to the asking copy for good reason: those *are* per-checkout facts,
  # and showing an agent 1138 credo problems from a worktree it cannot fix is
  # the failure that scoping exists to prevent. A file's existence is not that.
  #
  # The best verdict wins where copies disagree — one that has scanned and
  # approved the file outranks one that has not caught up, because a spec that
  # is valid somewhere is written.
  defp best_report(scope, spec_path) do
    %{scope | active_working_copy_id: nil}
    |> Files.get_by_paths([spec_path])
    |> Enum.sort_by(fn
      %{valid: true} -> 0
      %{valid: false} -> 1
      _ -> 2
    end)
    |> List.first()
  end

  # "Not found" is also what this says when the file is present and the lookup
  # could not see it — wrong project, wrong working copy, or a scope carrying
  # neither. Three separate defects have now hidden behind that one sentence
  # (dca0bea9, d5fd302e, 6b2810a8), and each cost a diagnosis because the
  # message named the file, which is the one thing that was never wrong.
  #
  # So it says where it looked. A refusal that names its own scope can be
  # checked against the row in one step instead of five.
  defp where(:file_not_found, scope) do
    "\n  Looked in: project #{inspect(scope.active_project_id)}" <>
      ", working copy #{inspect(scope.active_working_copy_id)}"
  end

  defp where(_reason, _scope), do: ""

  # The harness's verdict wins wherever it exists, and the disk is the fallback
  # rather than the other way round.
  #
  # Keying on `environment: nil` was the wrong test. It asks whether a scope has
  # an environment, when the question is whether *this server* can read one — and
  # those differ exactly when a scope carries an environment that lives on
  # another machine. There `Environments.read_file/2` fails, the catch-all below
  # turns that into `:file_not_found`, and every criterion is reported missing
  # for specs that are on disk and that the harness has already scanned and
  # approved.
  #
  # Measured on story 966: eleven criteria reported "Spec file not found" while
  # `files` held all eleven at exactly those paths with `valid: true`, and
  # `bdd_specs_exist` was satisfied by the same rows in the same second. The
  # agent could not clear it by any edit, because the answer never depended on
  # the file's contents.
  #
  # Inverting the order fixes that and keeps the older-scanner case: a harness
  # that sends no verdict (`:no_verdict`) or has no row yet falls through to the
  # disk, which is what the environment branch is actually for.
  defp spec_checker(scope) do
    fn spec_path ->
      case from_file_report(scope, spec_path) do
        {:error, reason} when reason in [:file_not_found, :no_verdict] ->
          from_disk(scope, spec_path, reason)

        result ->
          result
      end
    end
  end

  defp from_disk(%{environment: nil}, _spec_path, reported), do: {:error, reported}

  defp from_disk(%{environment: env}, spec_path, reported) do
    case validate_single_spec(env, spec_path) do
      # No disk here either. The file report's answer is the better of the two,
      # because it at least describes a machine that has one.
      {:error, :no_environment} -> {:error, reported}
      result -> result
    end
  end

  # The manifest is the whole truth — a path absent from it is a deletion, not
  # an omission — so no row here really is "not found", and says so.
  defp from_file_report(scope, spec_path) do
    case best_report(scope, spec_path) do
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

  # `mix.exs` first, because it is the app name the project actually compiles
  # under. When it cannot be read, the project's own module name — not
  # `my_app`.
  #
  # That placeholder reached agents as real instructions. On a light harness the
  # server has no working copy, so this read never succeeds, and the prompt told
  # spec-writers to `use MyAppSpex.Case` and pointed at
  # `test/support/my_app_spex_case.ex` — none of which exist in any project. The
  # surrounding prose names real criteria and real paths, so the placeholders
  # read as deliberate rather than as an unsubstituted template.
  defp derive_app_name(scope) do
    case scope.environment && Environments.read_file(scope.environment, "mix.exs") do
      {:ok, content} -> extract_app_name(content, scope)
      _ -> app_name_from_project(scope)
    end
  end

  defp app_name_from_project(%{active_project: %{module_name: module_name}})
       when is_binary(module_name) and module_name != "",
       do: Macro.underscore(module_name)

  defp app_name_from_project(_scope), do: "my_app"

  # A `mix.exs` that was read but whose `app:` could not be found falls back the
  # same way, for the same reason: `my_app` is a name no project has.
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
