defmodule CodeMySpec.Files.Scanner do
  @moduledoc """
  Observes the filesystem and reports what it finds. The device half of file
  sync.

  Everything here needs the working copy: walking it, hashing it, reading file
  contents to decide whether a spec is valid. None of it needs the database,
  and nothing it returns contains file content — validation happens here and
  only its verdict travels.

  That is the point of the split. `FileSync` turns these observations into
  File rows, links them to components and stories, and reconciles them against
  what is already stored. Those are interpretations, and they can run anywhere.
  Scanning cannot: it has to be where the files are.

  The one thing scanning needs from the domain is a `ReadModel` — component
  module names, the project's story ids, and whether spec validation is strict.
  It is small, it changes slowly, and it is passed in rather than queried so
  this module holds no repo of its own.
  """

  alias CodeMySpec.BddSpecs.ContentCheck
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.ComponentExtract
  alias CodeMySpec.Paths
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment

  # The subtrees a sync walks. Everything outside them is invisible to the
  # domain, which is what keeps a project's own deps/ and _build/ out of it.
  #
  # `bin`, `.github`, `config`, `rel`, `envs`, `Dockerfile`, `.sops.yaml` and
  # the plaintext env names joined 2026-08-30: `DeployBoilerplate`'s own
  # manifest lives entirely outside the original list, so a harness-scoped
  # devops call's fallback to this table could never see it regardless of
  # whether sync itself worked — confirmed live against MarketMySpec, whose
  # sync was genuinely healthy (a real scan, a real reconcile, real rows) and
  # still reported every boilerplate artifact missing, because none of those
  # paths were ever walked. Each of these is small and bounded the same way
  # `lib`/`test` already are — nothing here risks the `deps`/`_build` problem
  # this list exists to avoid.
  @sync_roots [
    "lib",
    "test",
    "bin",
    ".github",
    "config",
    "rel",
    "envs",
    Paths.base_dir(),
    "CLAUDE.md",
    "mix.exs",
    ".credo.exs",
    "Dockerfile",
    ".sops.yaml",
    ".env",
    ".env.local",
    ".env.production",
    ".env.schema"
  ]

  # Directories the walker never descends into. Build output and vendored
  # source are not the project's own files.
  @ignored_dirs ~w(deps _build .git node_modules .elixir_ls .lexical)

  defmodule ReadModel do
    @moduledoc """
    The slice of the domain that scanning needs.

    `component_by_module` resolves a file path to its owning component;
    `component_by_id` gives `validate_test_alignment/3` the module name it
    needs to find the matching spec; `strict?` is the project's
    require-specs setting.

    The two path families name a story with two different identifiers, so
    they get two lookups. `.code_my_spec/qa/<id>/` is the primary key —
    `story_ids` is its existence check. `test/spex/<number>_<slug>/` is the
    durable number — `story_ids_by_number` resolves it to an id. One map
    served both while the two identifiers were the same value; once they
    diverged, every spex directory resolved to nothing and the files it held
    were owned by no story, so `bdd_specs_passing` could never be satisfied.

    `component_by_path` is the component-side version of that same move.
    `component_by_module` requires deriving a module name from a path, and that
    derivation cannot be made correct: `Macro.underscore/1` destroys
    capitalization and `Macro.camelize/1` cannot restore it, so
    `code_my_spec/git/cli` comes back as `Git.Cli` and never matches
    `Git.CLI`. Projecting the known module names *forward* into paths is exact,
    so this map is built that way and the path is looked up. See
    `Components.ConventionalPaths`.

    `story_by_spec_path` is the one that does not guess. A criterion records
    which file is its spex, so a spex file's story is a lookup rather than a
    number parsed out of a directory name. That parse survives only as the
    fallback for files nothing has claimed yet.

    The parse is wrong exactly when a project has been migrated: story ids are
    per-deployment, so every directory then names a story that has a different
    id here. On this project it left 76 stories unable to satisfy
    `bdd_specs_exist` while their spex sat on disk, and bound 8 more to
    whichever story happened to share a number with an old directory —
    "OAuth registration logs the user in" holding subagent-dispatch spex.
    """
    defstruct component_by_module: %{},
              component_by_path: %{},
              component_by_id: %{},
              story_ids: MapSet.new(),
              story_ids_by_number: %{},
              story_by_spec_path: %{},
              strict?: true

    @type t :: %__MODULE__{
            component_by_module: %{String.t() => Ecto.UUID.t()},
            component_by_path: %{String.t() => Ecto.UUID.t()},
            component_by_id: %{Ecto.UUID.t() => struct()},
            story_ids: MapSet.t(integer()),
            story_ids_by_number: %{integer() => integer()},
            story_by_spec_path: %{String.t() => integer()},
            strict?: boolean()
          }
  end

  @doc """
  Walk, classify, stat, link, fingerprint and validate — the whole device-side
  pipeline, in the order the fields depend on each other.

  Ownership is resolved before validation because `validate_entry/4` dispatches
  on `component_id` for `:test` files.

  Returns `{:error, reason}` when the environment does not scan. It used to
  return `[]` there, which is the same value a genuinely empty working copy
  produces — and a caller cannot tell those apart, so it deletes.

  `FileSync.sync/2` did exactly that. Running on the server, whose environment
  is a `Harness` with no tree to walk, it took the empty list as a snapshot and
  `Files.delete_removed/2` removed all 3936 rows for the working copy plus 452
  of its Problems. The harness re-sent its manifest, the rows came back, and the
  next `get_next_requirement` deleted them again — so asking what to work on
  next destroyed the projection it had just answered from, and the answer was
  `implementation_file` for `CodeMySpec.Authorization`, a module committed
  months ago with eleven call sites.
  """
  @spec observe(Environments.Environment.t(), ReadModel.t()) :: {:ok, [map()]} | {:error, term()}
  def observe(env, %ReadModel{} = read_model) do
    case stream_files(env) do
      {:error, reason} ->
        {:error, reason}

      {:ok, stream} ->
        entries =
          stream
          |> Enum.to_list()
          |> then(&fingerprint_entries(env, &1))
          |> resolve_owners(read_model)
          |> Enum.map(&validate_entry(&1, env, read_model.component_by_id, read_model.strict?))

        {:ok, entries}
    end
  end

  @doc """
  Paths under the sync roots that no clause of `classify/1` claims.

  These are dropped by `stream_files/1`, and until now they were dropped in
  silence — which is the single most expensive piece of missing information in
  this system. An unclassified file never syncs, so the scan reports a
  *constant* file count while an agent keeps writing, and the requirement that
  gates on it reports it missing while it sits on disk.

  That reads exactly like a dead file watcher. Three drills were spent trying to
  revive watchers that were scanning every forty-five seconds and having every
  manifest accepted; the answer each time was one unclassified path.

  Most of what this returns is legitimately ignorable — test-support scaffolding,
  fixtures, page content. The point is not that the list is empty. It is that
  the list is *visible*, so "the harness cannot see my file" and "the harness
  chose not to track my file" stop looking the same.
  """
  @spec unclassified(Environments.Environment.t()) :: [String.t()]
  def unclassified(env) do
    env
    |> Environments.stream_files(@sync_roots)
    |> Stream.filter(&(classify(&1) == nil))
    |> Enum.to_list()
  end

  def fingerprint_entries(env, entries) do
    Enum.map(entries, &add_fingerprint(env, &1))
  end

  defp add_fingerprint(env, entry) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        entry
        |> Map.put(:fingerprint, fingerprint(content))
        |> put_declared_module(content)

      {:error, _} ->
        Map.put(entry, :fingerprint, nil)
    end
  end

  # What the file says it is, learned during the read that fingerprints it.
  #
  # `resolve_owners/2` prefers this over the module implied by the path, because
  # Phoenix does not put every module where its name suggests —
  # `MyAppWeb.CoreComponents` lives under `components/`, `MyAppWeb.ErrorHTML`
  # under `controllers/`. Deriving from the path makes those owned by nothing,
  # and their `implementation_file` requirements unsatisfiable by any correct
  # work.
  defp put_declared_module(%{role: :implementation} = entry, content),
    do: Map.put(entry, :declared_module, ComponentExtract.extract_defmodule(content))

  defp put_declared_module(entry, _content), do: entry

  defp fingerprint(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Stream and classify all trackable files under the sync whitelist roots.

  `{:ok, stream}` of maps with `:path`, `:role`, `:mtime`, `:size`, paths
  relative to `env.cwd` — or `{:error, reason}` from an environment that does
  not walk a working copy. Same contract as `observe/2` and for the same
  reason: the refusal has to stay distinguishable from an empty tree, because
  the caller's next move is to delete everything the walk did not mention.
  """
  @spec stream_files(Environments.Environment.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_files(env) do
    case Environments.stream_files(env, @sync_roots) do
      {:error, reason} -> {:error, reason}
      stream -> {:ok, classified(stream, env)}
    end
  end

  # The half of the walk that turns paths into entries. Shared with `observe/2`.
  #
  # A `scannable/1` clause used to sit ahead of this, folding
  # `{:error, :not_supported_on_harness}` into `[]` so the stream stayed a
  # stream. Its own comment closed with "turning the second into an empty
  # working copy is how a sync deletes everything it could not see", which is
  # what it then did — twice, 3936 rows and 452 Problems each time. Both
  # entry points return the refusal now, so there is nothing left to fold.
  defp classified(stream, env) do
    stream
    |> Stream.map(&classify/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn {path, role} -> stat_file(env, path, role) end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Validate a file entry based on its role.

  Specs and reviews are validated via `Documents.create_dynamic_document`.
  Tests with a component are checked for spec alignment.
  Other tracked roles are valid by existence.
  """
  def validate_entry(entry, env, component_by_id, strict? \\ true)

  def validate_entry(%{role: :spec} = entry, env, _component_by_id, strict?) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        document_type = document_type_from_content(content)
        validate_spec_content(entry, content, document_type, strict?)

      {:error, reason} ->
        Map.merge(entry, %{
          valid: false,
          validation_errors: %{"error" => "Read failed: #{inspect(reason)}"}
        })
    end
  end

  # Spex files are checked here, on the machine that has them, for the same
  # reason `:spec` and `:review` are: the server may hold no working copy, and
  # something that can only validate by reading a disk answers "not found" for
  # every file when there is no disk to read. That is exactly what happened —
  # six specs reported missing in a stop no edit could clear, while the
  # requirement graph read this same report and correctly found them present.
  #
  # Only the verdict travels. `ContentCheck` is pure so it can run here without
  # a database and without shipping file content anywhere.
  def validate_entry(%{role: :bdd_spec} = entry, env, _component_by_id, _strict?) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        case ContentCheck.check(content, entry.path) do
          :ok ->
            Map.merge(entry, %{valid: true, validation_errors: %{}})

          {:error, reason} ->
            Map.merge(entry, %{
              valid: false,
              validation_errors: %{"reason" => ContentCheck.describe(reason, entry.path)}
            })
        end

      {:error, reason} ->
        Map.merge(entry, %{
          valid: false,
          validation_errors: %{"reason" => "Read failed: #{inspect(reason)}"}
        })
    end
  end

  def validate_entry(%{role: :review} = entry, env, _component_by_id, strict?) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        validate_spec_content(entry, content, "design_review", strict?)

      {:error, reason} ->
        Map.merge(entry, %{
          valid: false,
          validation_errors: %{"error" => "Read failed: #{inspect(reason)}"}
        })
    end
  end

  def validate_entry(
        %{role: :test, component_id: component_id} = entry,
        env,
        component_by_id,
        _strict?
      )
      when not is_nil(component_id) do
    component = Map.get(component_by_id, component_id)

    if component do
      validate_test_alignment(entry, env, component)
    else
      Map.merge(entry, %{valid: true, validation_errors: nil})
    end
  end

  # Setup artifacts: each validator runs all the per-concern checks the setup
  # steps used to do at evaluate-time, and persists the results into
  # `validation_errors` keyed by concern. The corresponding Setup.* step then
  # decides pass/fail by reading those keys — zero filesystem access.
  def validate_entry(%{role: :mix_exs} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_mix_exs/1)
  end

  def validate_entry(%{role: :credo_exs} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_credo_exs/1)
  end

  def validate_entry(%{role: :claude_md} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_claude_md/1)
  end

  def validate_entry(%{role: :setup_config} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_setup_config/1)
  end

  def validate_entry(%{role: :test_support} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_test_support(&1, entry.path))
  end

  # Persona artifacts follow the setup pattern for the same reason: the
  # verdict has to survive the trip to a server that cannot read the file.
  # `PersonasChecker` used to read and validate these itself and could not do
  # it at all without a disk.
  # Parsed against the registered `qa_plan` document spec at sync time, so the
  # requirement reads a verdict instead of a file.
  def validate_entry(%{role: :qa_plan} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_qa_plan(&1, entry.path))
  end

  def validate_entry(%{role: :persona_summary} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_persona_summary/1)
  end

  def validate_entry(%{role: :persona_sources} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_persona_sources/1)
  end

  def validate_entry(%{role: :implementation} = entry, env, _component_by_id, _strict?) do
    # Not "valid by existence" any more, but the validity claim is unchanged —
    # an implementation file is valid because it is there. What is new is the
    # module name travelling with it, which `ComponentSync` used to open the
    # file to learn.
    #
    # `ecto_schema` travels the same way and for the same reason: the content is
    # already in hand here, so recording it costs nothing, where inferring it in
    # `ComponentSync` would mean re-opening every implementation file on the
    # project. It is the one type fact read from an implementation — see
    # `ComponentExtract.ecto_schema?/1` for why schemas are the exception.
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        Map.merge(entry, %{
          valid: true,
          validation_errors: %{
            "errors" => %{},
            "data" => %{
              "module_name" => ComponentExtract.extract_defmodule(content),
              "ecto_schema" => ComponentExtract.ecto_schema?(content)
            }
          }
        })

      {:error, _reason} ->
        Map.merge(entry, %{valid: true, validation_errors: nil})
    end
  end

  @valid_by_existence_roles [
    :test,
    :rule,
    :config,
    :bdd_spec,
    :qa_brief,
    :qa_result,
    :qa_script,
    :json,
    :review,
    :architecture,
    :credo_check,
    :integration,
    :agents_md,
    :project_knowledge,
    :hex_doc,
    :deploy_artifact
  ]

  def validate_entry(%{role: role} = entry, _env, _component_by_id, _strict?)
      when role in @valid_by_existence_roles do
    # These roles are valid if they exist (which they do, since FileSync found them)
    Map.merge(entry, %{valid: true, validation_errors: nil})
  end

  def validate_entry(entry, _env, _component_by_id, _strict?) do
    Map.merge(entry, %{valid: nil, validation_errors: nil})
  end

  defp validate_test_alignment(entry, env, component) do
    module_path = Macro.underscore(component.module_name) |> String.replace(".", "/")
    spec_path = Paths.spec_file(module_path)

    with {:ok, spec_content} <- Environments.read_file(env, spec_path),
         {:ok, test_content} <- Environments.read_file(env, entry.path) do
      case SpecAlignment.check_test_alignment(spec_content, test_content) do
        {:ok, :aligned} ->
          Map.merge(entry, %{valid: true, validation_errors: nil})

        {:ok, :misaligned, errors} ->
          Map.merge(entry, %{valid: false, validation_errors: errors})
      end
    else
      {:error, _} ->
        # No spec file or can't read test — valid by default
        Map.merge(entry, %{valid: true, validation_errors: nil})
    end
  end

  # -- Setup-artifact validators --
  #
  # Each validator returns `%{errors: map, data: map}`:
  # - `errors` keys are concerns (atom-stringified by JSON when round-tripping
  #   the DB :map column). Value `nil` = concern passes; string = fail message.
  # - `data` keys are facts (e.g. extracted app_name) that other Setup.* steps
  #   need to consume. Not part of validity.
  #
  # `valid` is true iff every value in `errors` is nil. Setup.* steps read both
  # maps off the persisted File record's `validation_errors` and use the data
  # for cross-file decisions (e.g. TestSupportNamespace needs app_name from
  # mix_exs to know what namespace to look for in conn_case / data_case).

  # Both lifted verbatim from `PersonasChecker`, which ran them against a disk
  # at evaluate time. Same rules, decided once at sync and carried in
  # `validation_errors` so a server with no working copy can still read the
  # verdict.
  # Two files share this role and they are *not* the same document. `plan.md`
  # parses as `qa_plan`, `journey_plan.md` as `qa_journey_plan` — both registered,
  # with different required sections. Validating the journey plan against the
  # other schema marked a perfectly good file invalid, which is worse than not
  # validating it: an agent is told to fix something that is already right.
  defp validate_qa_plan(content, path) do
    {doc_type, label} =
      if path == Paths.qa_journey_plan(),
        do: {"qa_journey_plan", "journey_plan.md"},
        else: {"qa_plan", "plan.md"}

    error =
      if String.trim(content) == "" do
        "`#{label}` is empty"
      else
        case Documents.create_dynamic_document(content, doc_type) do
          {:ok, _document} -> nil
          {:error, reason} -> "`#{label}` invalid — #{reason}"
        end
      end

    %{errors: %{plan: error}, data: %{}}
  end

  defp validate_persona_summary(content) do
    error =
      if String.trim(content) == "" do
        "`summary.md` is empty"
      else
        case Documents.create_dynamic_document(content, "persona_summary") do
          {:ok, _document} -> nil
          {:error, reason} -> "`summary.md` invalid — #{reason}"
        end
      end

    %{errors: %{summary: error}, data: %{}}
  end

  # workflow.md: "Link list with URL, title, and access date per entry — one per
  # line." Entries are markdown list items; each needs a URL and a YYYY-MM-DD
  # date, with the title between them.
  defp validate_persona_sources(content) do
    entries =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.starts_with?(&1, "- ") or String.starts_with?(&1, "* ")))

    invalid =
      Enum.find(entries, fn line ->
        not (Regex.match?(~r{https?://\S+}, line) and
               Regex.match?(~r/\b\d{4}-\d{2}-\d{2}\b/, line))
      end)

    error =
      cond do
        entries == [] ->
          "`sources.md` has no entries — expected one markdown list item per " <>
            "source (URL — title — access date)"

        invalid != nil ->
          "`sources.md` entry missing URL or YYYY-MM-DD date: " <>
            String.slice(invalid, 0, 80)

        true ->
          nil
      end

    %{errors: %{sources: error}, data: %{entry_count: length(entries)}}
  end

  defp component_data(content) do
    %{
      "errors" => %{},
      "data" => %{
        "module_name" => ComponentExtract.extract_h1_module(content),
        "type" => ComponentExtract.extract_type_section(content),
        "description" => ComponentExtract.extract_intro_text(content),
        "dependencies" => ComponentExtract.extract_dependencies(content)
      }
    }
  end

  defp validate_setup_file(entry, env, validator) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        %{errors: errors, data: data} = validator.(content)
        all_pass? = Enum.all?(errors, fn {_, v} -> is_nil(v) end)

        Map.merge(entry, %{
          valid: all_pass?,
          validation_errors: %{"errors" => stringify_keys(errors), "data" => stringify_keys(data)}
        })

      {:error, reason} ->
        Map.merge(entry, %{
          valid: false,
          validation_errors: %{
            "errors" => %{"read" => "Read failed: #{inspect(reason)}"},
            "data" => %{}
          }
        })
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @required_mix_deps [
    :credo,
    :client_utils,
    :sobelow,
    :sexy_spex,
    :boundary,
    :code_my_spec_generators
  ]

  defp validate_mix_exs(content) do
    {app_name_value, app_name_error} = extract_app_name_result(content)

    %{
      errors: %{
        app_name: app_name_error,
        compilers: validate_compilers(content),
        codemyspec_deps: validate_codemyspec_deps(content),
        spex_config: validate_spex_config(content)
      },
      data: %{app_name: app_name_value}
    }
  end

  defp extract_app_name_result(content) do
    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> {name, nil}
      _ -> {nil, "Cannot extract app name from `mix.exs`"}
    end
  end

  defp validate_compilers(content) do
    has_boundary = Regex.match?(~r/compilers.*:boundary/s, content)
    has_spex = Regex.match?(~r/compilers.*:spex/s, content)

    if has_boundary and has_spex,
      do: nil,
      else: "Compilers not configured in `mix.exs` (need :boundary and :spex)"
  end

  defp validate_codemyspec_deps(content) do
    missing =
      Enum.reject(@required_mix_deps, fn dep ->
        Regex.match?(~r/\{:#{Atom.to_string(dep)}[,\s]/, content)
      end)

    if missing == [],
      do: nil,
      else: "Missing deps in `mix.exs`: #{Enum.map_join(missing, ", ", &":#{&1}")}"
  end

  defp validate_spex_config(content) do
    if Regex.match?(~r/spex:\s*:test/, content),
      do: nil,
      else: "`spex: :test` not found in preferred_envs in `mix.exs`"
  end

  defp validate_credo_exs(content) do
    has_requires =
      String.contains?(content, "credo_checks/framework") and
        String.contains?(content, "credo_checks/local")

    has_eval = String.contains?(content, "credo_checks/framework/checks.exs")

    error =
      if has_requires and has_eval do
        nil
      else
        "`.credo.exs` missing custom check configuration (requires + eval_file)"
      end

    %{errors: %{custom_checks: error}, data: %{}}
  end

  defp validate_claude_md(content) do
    error =
      if String.contains?(content, "<!-- code_my_spec:start -->") do
        nil
      else
        "`CLAUDE.md` exists but missing CodeMySpec managed section"
      end

    %{errors: %{managed_section: error}, data: %{}}
  end

  defp validate_setup_config(content) do
    error =
      case YamlElixir.read_from_string(content) do
        {:ok, _} -> nil
        _ -> "`.code_my_spec/config.yml` is not valid YAML"
      end

    %{errors: %{config_yaml: error}, data: %{}}
  end

  # test/support files: which checks apply depends on filename. Dispatch on
  # basename so each variant is a focused function. conn_case/data_case can't
  # decide validity unilaterally (depends on app name from mix_exs), so they
  # store the module name in `data` and the step does the cross-file compare.
  defp validate_test_support(content, path) do
    do_validate_test_support(Path.basename(path), content, path)
  end

  defp do_validate_test_support("conn_case.ex", content, path),
    do: validate_test_support_case(content, path)

  defp do_validate_test_support("data_case.ex", content, path),
    do: validate_test_support_case(content, path)

  defp do_validate_test_support(base, content, path) do
    case test_support_kind(base) do
      :boundary -> validate_test_support_boundary(content, path)
      :spex_case -> validate_test_support_spex_case(content, path)
      :unknown -> %{errors: %{}, data: %{}}
    end
  end

  defp test_support_kind(base) do
    cases = [
      {"_spex.ex", :boundary},
      {"_test_boundary.ex", :boundary},
      {"_spex_case.ex", :spex_case}
    ]

    Enum.find_value(cases, :unknown, fn {suffix, kind} ->
      if String.ends_with?(base, suffix), do: kind
    end)
  end

  defp validate_test_support_boundary(content, path) do
    error =
      if String.contains?(content, "use Boundary"),
        do: nil,
        else: "Missing `use Boundary` in `#{path}`"

    %{errors: %{has_use_boundary: error}, data: %{}}
  end

  defp validate_test_support_spex_case(content, path) do
    required = ["use SexySpex", "import Phoenix.LiveViewTest"]
    defmodule_ok = Regex.match?(~r/defmodule \S+Spex\.Case/, content)
    missing = Enum.reject(required, &String.contains?(content, &1))

    %{errors: %{spex_case_module: spex_case_error(defmodule_ok, missing, path)}, data: %{}}
  end

  defp spex_case_error(false, _missing, path),
    do: "`#{path}` missing `defmodule <App>Spex.Case`"

  defp spex_case_error(true, [], _path), do: nil

  defp spex_case_error(true, missing, path),
    do: "`#{path}` missing: #{Enum.join(missing, ", ")}"

  defp validate_test_support_case(content, path) do
    module_name =
      case Regex.run(~r/defmodule\s+(\S+)\b/, content) do
        [_, mod] -> mod
        _ -> nil
      end

    error = if module_name, do: nil, else: "`#{path}` has no defmodule"

    %{errors: %{has_defmodule: error}, data: %{module_name: module_name}}
  end

  defp validate_spec_content(entry, content, document_type, strict?) do
    case Documents.create_dynamic_document(content, document_type, strict: strict?) do
      {:ok, _document} ->
        # Carries the component identity, so `ComponentSync` does not have to
        # re-read the file to find it. Stored even for an otherwise clean spec
        # because "valid" and "names a component" are different questions.
        Map.merge(entry, %{valid: true, validation_errors: component_data(content)})

      {:error, error} ->
        Map.merge(entry, %{valid: false, validation_errors: %{"error" => to_string(error)}})
    end
  rescue
    e ->
      Map.merge(entry, %{valid: false, validation_errors: %{"error" => Exception.message(e)}})
  end

  # Extract document type from spec content's ## Type section.
  # Maps component types to document types via the registry.
  #
  # CRLF → LF first: a Windows-written spec has `## Type\r`, and `^## Type$`
  # won't match (the `\r` is before the line end), so the type silently
  # resolves to the default "spec" definition and the wrong section set is
  # enforced. Same class as the ComponentSync CRLF fix.
  defp document_type_from_content(content) do
    type_section =
      content
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    case type_section do
      nil ->
        "spec"

      component_type ->
        type_def = ComponentRegistry.get_type(component_type)
        Map.get(type_def, :document_type, "spec")
    end
  end

  @doc """
  Classify a relative path into a file role.

  Returns `{path, role}` or `nil` if the path doesn't match any known pattern.
  """
  @spec classify(String.t()) :: {String.t(), atom()} | nil
  def classify(path) do
    Enum.find_value(
      [
        &classify_setup_artifact/1,
        &classify_spec_or_review/1,
        &classify_code/1,
        &classify_credo_check/1,
        &classify_docs/1,
        &classify_qa/1,
        &classify_config/1,
        &classify_deploy_artifact/1
      ],
      & &1.(path)
    )
  end

  # `DeployBoilerplate`'s own manifest — walked since `bin`/`.github`/`config`/
  # `rel`/`envs` joined `@sync_roots`, but a walk alone answers nothing: the
  # scan pipeline drops anything `classify/1` returns nil for before it ever
  # reaches a `File` row (`classified/2`'s own `Stream.reject(&is_nil/1)`).
  # Existence is all `DeployBoilerplate.present?/2` ever asks of these, so one
  # role covers the whole manifest rather than one per artifact.
  @deploy_artifact_dirs ~w(bin/ .github/ config/ rel/ envs/)
  @deploy_artifact_files ~w(Dockerfile .sops.yaml .env .env.local .env.production .env.schema)

  defp classify_deploy_artifact(path) do
    if path in @deploy_artifact_files or Enum.any?(@deploy_artifact_dirs, &String.starts_with?(path, &1)),
      do: {path, :deploy_artifact}
  end

  # Setup-time artifacts. Validated at sync time so the requirements graph
  # can decide `project_setup` satisfaction with O(1) DB lookups instead of
  # re-reading these files on every render.
  defp classify_setup_artifact(path) do
    cond do
      path == "mix.exs" -> {path, :mix_exs}
      path == ".credo.exs" -> {path, :credo_exs}
      path == "CLAUDE.md" -> {path, :claude_md}
      path == Path.join(Paths.base_dir(), "AGENTS.md") -> {path, :agents_md}
      path == Path.join(Paths.base_dir(), "config.yml") -> {path, :setup_config}
      test_support?(path) -> {path, :test_support}
      true -> nil
    end
  end

  # Five files in test/support/ are setup artifacts (boundary defs, ConnCase/
  # DataCase, the Spex.Case template). The first three are app-name-prefixed.
  defp test_support?(path) do
    base = Path.basename(path)

    # The fixtures bridge `SpexBoundaryChecker` looks for. `.ex` files
    # under test/ match no other classifier — `classify_code/1` claims
    # only `_test.exs` and `_spex.exs` there — so this went unsynced and
    # the checker could only find it by statting a disk.
    # `do_validate_test_support/3` treats an unrecognised basename as
    # valid-by-existence, which is exactly the claim being made here.
    String.starts_with?(path, "test/support/") and
      (String.ends_with?(base, "_spex.ex") or
         String.ends_with?(base, "_test_boundary.ex") or
         String.ends_with?(base, "_spex_case.ex") or
         String.ends_with?(base, "_spex_fixtures.ex") or
         base == "conn_case.ex" or
         base == "data_case.ex")
  end

  defp classify_spec_or_review(path) do
    spec_prefix = Paths.spec_dir() <> "/"

    cond do
      String.starts_with?(path, spec_prefix) and String.ends_with?(path, ".spec.md") ->
        {path, :spec}

      String.starts_with?(path, spec_prefix) and String.ends_with?(path, "/design_review.md") ->
        {path, :review}

      true ->
        nil
    end
  end

  defp classify_code(path) do
    cond do
      String.starts_with?(path, "test/spex/") and String.ends_with?(path, "_spex.exs") ->
        {path, :bdd_spec}

      String.starts_with?(path, "test/") and String.ends_with?(path, "_test.exs") ->
        {path, :test}

      String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex") ->
        {path, :implementation}

      true ->
        nil
    end
  end

  # Each tuple is `{dir_fn, role}` — a path under that directory ending
  # in `.md` classifies as that role. Order doesn't matter; the dirs
  # don't overlap.
  #
  # Framework knowledge (the `"knowledge"` source) is intentionally
  # absent — it lives in `priv/knowledge/` and is embedded directly
  # by `Embeddings.sync_framework_knowledge/1`. Nothing under the
  # project tree resolves to that role.
  defp doc_dir_roles do
    [
      {&Paths.rules_dir/0, :rule},
      {&Paths.architecture_dir/0, :architecture},
      {&Paths.integrations_dir/0, :integration},
      {&Paths.knowledge_dir/0, :project_knowledge},
      {&Paths.hex_docs_dir/0, :hex_doc}
    ]
  end

  # `.code_my_spec/credo_checks/**/*.ex[s]`.
  #
  # `classify_code/1` only claims `lib/` and `test/`, and `classify_docs/1`
  # only claims `.md`, so these fell between the two and never synced at all —
  # which is why `SpexBoundaryChecker` had to stat them and could not run
  # without a disk.
  #
  # Both extensions: the framework ships `checks.exs` beside the `.ex` checks,
  # and a checker that wants only one can filter. Syncing less than is there
  # is how a directory listing and a file table stop agreeing.
  defp classify_credo_check(path) do
    if String.starts_with?(path, Paths.credo_checks_dir() <> "/") and
         (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")),
       do: {path, :credo_check}
  end

  defp classify_docs(path) do
    classify_persona(path) ||
      if String.ends_with?(path, ".md") do
        exact_doc_role(path) || Enum.find_value(doc_dir_roles(), &match_doc_dir(path, &1))
      end
  end

  # `.code_my_spec/integrations.md` is a sibling of `integrations/`, not a file
  # inside it, so `match_doc_dir/2` — which requires the trailing slash — never
  # claimed it and it never synced.
  #
  # `QaIntegrationPlan` reads it twice: `check_index/1` is the first gate of its
  # state machine, and writing it is half the task's stated done signal. So an
  # agent could do exactly what it was told, write the index, and the graph
  # fingerprint would not move — the requirement stays unsatisfied and the
  # agent is handed the same instruction again.
  defp exact_doc_role(path) do
    if path == Paths.integrations_index(), do: {path, :integration}
  end

  # `.code_my_spec/personas/<slug>/{summary,sources}.md`.
  #
  # Their own roles rather than a shared `:persona`, because each is validated
  # differently — the summary against a document schema, the sources against a
  # line format — and `PersonasChecker` reports them as separate gaps.
  #
  # Anything else in the folder is unclassified and therefore never synced,
  # which costs the old stray-file rule — see `PersonasChecker`.
  defp classify_persona(path) do
    prefix = Paths.personas_dir() <> "/"

    with true <- String.starts_with?(path, prefix),
         [_slug, file] <- path |> String.replace_prefix(prefix, "") |> Path.split() do
      case file do
        "summary.md" -> {path, :persona_summary}
        "sources.md" -> {path, :persona_sources}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp match_doc_dir(path, {dir_fn, role}) do
    if String.starts_with?(path, dir_fn.() <> "/"), do: {path, role}
  end

  defp classify_qa(path) do
    cond do
      # The plans `qa_setup` and the journey requirements gate on. Neither
      # was classified, so neither ever synced, so the checkers had to read
      # them off a disk — and reported them missing on a server that has
      # none, while they sat in the agent's working copy.
      path in [Paths.qa_plan(), Paths.qa_journey_plan()] -> {path, :qa_plan}
      # The scripts the integration specs point at. `41406ceb`: classifying the
      # specs closed the fingerprint hole for their *contents*, but
      # `QaIntegrationPlan.check_one_verify_script/2` parses a path out of each
      # spec and asserts that file exists — and that file was claimed by
      # nothing, so creating the very script that satisfies the check left
      # `files_digest/1` unchanged and the published graph served as current.
      # Same defect as the specs had, one indirection along.
      #
      # `qa_integration_plan` is a graph requirement
      # (`requirement_definition_data.ex:900`), which is what makes the
      # fingerprint the mechanism here. `.code_my_spec/qa/summary.md` and
      # `.code_my_spec/design/design_system.html` are read by evaluators too and
      # are deliberately *not* claimed: `QaApp` and `DesignUi` are session types
      # started by hand, not graph nodes, so nothing caches a decision about
      # them and `read_file/2` answers over the channel on a light harness.
      # Unclassified is the right answer for a file no graph reads.
      match_qa_script?(path) -> {path, :qa_script}
      match_qa_file?(path, "brief.md") -> {path, :qa_brief}
      match_qa_result?(path) -> {path, :qa_result}
      true -> nil
    end
  end

  defp classify_config(path) do
    if path == Path.join(Paths.tasks_dir(), "code_generation.sh"),
      do: {path, :task_artifact}
  end

  # -- Private --

  @doc """
  Whether a path is excluded from sync. Public because `FileSync.sync_path/3`
  screens single-file events with it before doing any work.
  """
  def ignored_path?(path) do
    first_segment = path |> String.split("/") |> hd()
    first_segment in @ignored_dirs
  end

  # .code_my_spec/qa/{story_id}/brief.md
  defp match_qa_file?(path, filename) do
    qa_prefix = Paths.qa_dir() <> "/"
    String.starts_with?(path, qa_prefix) and String.ends_with?(path, "/" <> filename)
  end

  # Anything under `.code_my_spec/qa/scripts/`, without pinning an extension.
  # The specs name their verify script by path and nothing constrains it to
  # `.sh` — the three that exist happen to be shell, and a Python one would be
  # just as valid and just as invisible.
  #
  # Checked before `match_qa_file?/2` so a script named `brief.md` cannot be
  # taken for a story brief; the story-id parse would then fail on "scripts".
  defp match_qa_script?(path) do
    String.starts_with?(path, Paths.qa_scripts_dir() <> "/")
  end

  # Only result_complete.md satisfies the :qa_result role. In-progress
  # (result.md) and archived failures (result_failed_<ts>.md) live on disk
  # but aren't role-tagged — qa_complete must not be satisfied by an
  # unfinished or failed run.
  # `journey_result.md` is here because `qa_journey_execute` gates on it and it
  # matched nothing — the fifth artifact in this codebase that a requirement
  # required and the classifier had never heard of. See
  # `ClassifiableArtifactsTest`, which now enumerates them so there is not a
  # sixth.
  defp match_qa_result?(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    String.starts_with?(path, qa_prefix) and
      Path.basename(path) in ["result_complete.md", "journey_result.md"]
  end

  @doc "Stat a file for mtime and size. Returns entry map or nil if file doesn't exist."
  def stat_file(env, path, role) do
    case Environments.stat(env, path) do
      {:ok, %{mtime: mtime, size: size}} ->
        %{path: path, role: role, mtime: mtime, size: size}

      {:error, _} ->
        nil
    end
  end

  @doc "Resolve component_id and story_id owners for file entries."
  def resolve_owners(entries, %ReadModel{} = read_model) do
    # Ids parsed out of qa paths are only trusted if the project actually has
    # such a story — a stale directory name must not link a file to it.
    story_by_id =
      entries
      |> extract_qa_story_ids()
      |> Enum.filter(&MapSet.member?(read_model.story_ids, &1))
      |> Map.new(&{&1, &1})

    Enum.map(entries, fn entry ->
      {component_id, story_id} =
        case recorded_story(entry, read_model.story_by_spec_path) do
          nil ->
            owner_for(entry, read_model, story_by_id)

          story_id ->
            {nil, story_id}
        end

      # `:declared_module` is scratch for this decision and not a File field —
      # carrying it further reaches `insert_all` and fails there.
      entry
      |> Map.merge(%{component_id: component_id, story_id: story_id})
      |> Map.delete(:declared_module)
    end)
  end

  # What the file *declares* beats what its path implies.
  #
  # Phoenix does not put every module where its name suggests:
  # `E2eTodoWeb.CoreComponents` lives at
  # `lib/e2e_todo_web/components/core_components.ex`, and `E2eTodoWeb.ErrorHTML`
  # at `controllers/error_html.ex`. Deriving the module from the path reads
  # those as `E2eTodoWeb.Components.CoreComponents` and
  # `E2eTodoWeb.Controllers.ErrorHTML`, which match no component — so the files
  # are owned by nothing and their `implementation_file` requirements can never
  # be satisfied. The QA drill hit exactly four of these and correctly refused to
  # relocate framework files to satisfy a checker.
  #
  # `Files.Scanner` already extracts the `defmodule` from every implementation
  # file, so the answer is in the record. This is only populated after
  # `validate_entry/4`, which runs *after* this on the harness pass — harmless,
  # because the server re-resolves ownership on every manifest
  # (`FileSync.reconcile/2`) where it is present, and the path remains the
  # fallback for a spec or test that declares nothing.
  # Three sources, in descending order of how much they know.
  #
  # 1. The path, against components projected forward into their conventional
  #    paths. Exact.
  # 2. The module the file declares, which is what it actually is.
  # 3. A module name derived from the path — a guess, and one that cannot be
  #    made correct: `Macro.underscore/1` destroys capitalization and
  #    `Macro.camelize/1` cannot restore it, so `code_my_spec/git/cli` comes
  #    back `Git.Cli` and never matches `Git.CLI`.
  #
  # (3) alone is what left `Git.CLI` and `Git.URLParser` unresolvable. It stays
  # as the last resort because it still answers for files that are conventional
  # but belong to a component this read model has not seen, and being wrong
  # there costs an unowned file rather than a wrong owner. See
  # `Components.ConventionalPaths`.
  defp owner_for(entry, %ReadModel{} = read_model, _story_by_id)
       when is_map_key(entry, :role) and
              entry.role in [:implementation, :test, :spec] do
    by_module = read_model.component_by_module

    component_id =
      Map.get(read_model.component_by_path, entry.path) ||
        Map.get(by_module, declared_module(entry)) ||
        Map.get(by_module, path_to_module_name(entry.path, entry.role))

    {component_id, nil}
  end

  # test/spex/{story_number_and_title}/criterion_*_spex.exs → story
  #
  # Through `story_ids_by_number`, because the directory is named from the
  # durable number and every File row keys on the primary key. Handing the
  # number to a map of ids matched whichever story held that id, or nothing —
  # and nothing is what it does now on any project where the two differ.
  defp owner_for(%{path: path, role: :bdd_spec}, %ReadModel{} = read_model, _story_by_id) do
    story_number = extract_story_number_from_spex_path(path)
    {nil, Map.get(read_model.story_ids_by_number, story_number)}
  end

  defp owner_for(%{path: path, role: role}, %ReadModel{}, story_by_id)
       when role in [:qa_brief, :qa_result] do
    # .code_my_spec/qa/{story_id}/brief.md → story. The primary key here, not
    # the number: `QaStory` builds these paths from `story.id`.
    story_id = extract_story_id_from_qa_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(%{path: path, role: :review}, %ReadModel{} = read_model, _story_by_id) do
    # `.code_my_spec/spec/metric_flow/integrations/design_review.md` →
    # `MetricFlow.Integrations`. The path index answers this exactly — design
    # reviews are one of the paths `ConventionalPaths.for_component/1` projects
    # — and the derivation below carries the same capitalization loss as every
    # other path → module guess, so it is the fallback rather than the rule.
    module_name =
      path
      |> String.replace_prefix(Paths.spec_dir() <> "/", "")
      |> Path.dirname()
      |> path_segments_to_module()

    component_id =
      Map.get(read_model.component_by_path, path) ||
        Map.get(read_model.component_by_module, module_name)

    {component_id, nil}
  end

  defp owner_for(_entry, %ReadModel{}, _story_by_id), do: {nil, nil}

  # The `defmodule` the scan read out of the file, when it has been validated.
  # String keys because this arrives from the harness as JSON.
  defp declared_module(%{declared_module: name}) when is_binary(name) and name != "", do: name

  defp declared_module(%{validation_errors: %{"data" => %{"module_name" => name}}})
       when is_binary(name) and name != "",
       do: name

  defp declared_module(_entry), do: nil

  # .code_my_spec/qa/440/brief.md → 440
  defp extract_story_id_from_qa_path(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    path
    |> String.replace_prefix(qa_prefix, "")
    |> String.split("/")
    |> hd()
    |> parse_integer()
  end

  # test/spex/424_user_registration.../criterion_*_spex.exs → 424, the story's
  # durable number rather than its id.
  defp extract_story_number_from_spex_path(path) do
    path
    |> String.replace_prefix("test/spex/", "")
    |> String.split("/")
    |> hd()
    |> String.split("_")
    |> hd()
    |> parse_integer()
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {int, ""} -> int
      _ -> nil
    end
  end

  # The story a criterion says this file belongs to.
  #
  # Only for spex: a criterion records its own file, so this is a join rather
  # than a heuristic. Everything else keeps resolving by module name and path,
  # which is correct for them — an implementation file's owner really is
  # derivable from where it sits.
  #
  # `nil` when nothing has claimed the path, which sends the entry to the parse
  # below. That is right for a spex file written moments ago and not yet
  # recorded, and it is why the parse survives at all.
  defp recorded_story(%{role: :bdd_spec, path: path}, story_by_spec_path)
       when is_binary(path) do
    Map.get(story_by_spec_path, path)
  end

  defp recorded_story(_entry, _story_by_spec_path), do: nil

  # Only qa paths. Spex directories carry a number, which is resolved through
  # `story_ids_by_number` rather than checked for existence as an id.
  defp extract_qa_story_ids(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case entry.role do
        role when role in [:qa_brief, :qa_result] -> [extract_story_id_from_qa_path(entry.path)]
        _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp path_to_module_name(path, :implementation) do
    path
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> path_segments_to_module()
  end

  defp path_to_module_name(path, :test) do
    path
    |> String.replace_prefix("test/", "")
    |> String.replace_suffix("_test.exs", "")
    |> path_segments_to_module()
  end

  defp path_to_module_name(path, :spec) do
    path
    |> String.replace_prefix(Paths.spec_dir() <> "/", "")
    |> String.replace_suffix(".spec.md", "")
    |> path_segments_to_module()
  end

  defp path_segments_to_module(path) do
    path
    |> String.split("/")
    |> strip_convention_dirs()
    |> Enum.map_join(".", fn segment ->
      segment
      |> String.split("_")
      |> Enum.map_join(&String.capitalize/1)
    end)
  end

  # Phoenix convention: `live/` and `controllers/` are directory-only conventions
  # that don't map to module namespace segments.
  # e.g. "metric_flow_web/live/user_live/login" → "metric_flow_web/user_live/login"
  # Only strip when the convention dir is the second segment (directly under the web root).
  defp strip_convention_dirs([root, convention | rest])
       when convention in ["live", "controllers"] do
    [root | rest]
  end

  defp strip_convention_dirs(segments), do: segments
end
