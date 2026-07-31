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

  require Logger

  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment

  # The subtrees a sync walks. Everything outside them is invisible to the
  # domain, which is what keeps a project's own deps/ and _build/ out of it.
  @sync_roots ["lib", "test", Paths.base_dir(), "CLAUDE.md", "mix.exs", ".credo.exs"]

  # Directories the walker never descends into. Build output and vendored
  # source are not the project's own files.
  @ignored_dirs ~w(deps _build .git node_modules .elixir_ls .lexical)

  defmodule ReadModel do
    @moduledoc """
    The slice of the domain that scanning needs.

    `component_by_module` resolves a file path to its owning component;
    `component_by_id` gives `validate_test_alignment/3` the module name it
    needs to find the matching spec; `story_ids` is an existence check for
    ids parsed out of qa and spex paths; `strict?` is the project's
    require-specs setting.
    """
    defstruct component_by_module: %{},
              component_by_id: %{},
              story_ids: MapSet.new(),
              strict?: true

    @type t :: %__MODULE__{
            component_by_module: %{String.t() => Ecto.UUID.t()},
            component_by_id: %{Ecto.UUID.t() => struct()},
            story_ids: MapSet.t(integer()),
            strict?: boolean()
          }
  end

  @doc """
  Walk, classify, stat, link, fingerprint and validate — the whole device-side
  pipeline, in the order the fields depend on each other.

  Ownership is resolved before validation because `validate_entry/4` dispatches
  on `component_id` for `:test` files.
  """
  @spec observe(Environments.Environment.t(), ReadModel.t()) :: [map()]
  def observe(env, %ReadModel{} = read_model) do
    env
    |> stream_files()
    |> Enum.to_list()
    |> resolve_owners(read_model)
    |> then(&fingerprint_entries(env, &1))
    |> Enum.map(&validate_entry(&1, env, read_model.component_by_id, read_model.strict?))
  end

  def fingerprint_entries(env, entries) do
    Enum.map(entries, &add_fingerprint(env, &1))
  end

  defp add_fingerprint(env, entry) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} -> Map.put(entry, :fingerprint, fingerprint(content))
      {:error, _} -> Map.put(entry, :fingerprint, nil)
    end
  end

  defp fingerprint(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Stream and classify all trackable files under the sync whitelist roots.

  Returns a stream of maps with `:path`, `:role`, `:mtime`, `:size`. Paths are
  relative to `env.cwd`.
  """
  @spec stream_files(Environments.Environment.t()) :: Enumerable.t()
  def stream_files(env) do
    env
    |> Environments.stream_files(@sync_roots)
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
          validation_errors: %{error: "Read failed: #{inspect(reason)}"}
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
          validation_errors: %{error: "Read failed: #{inspect(reason)}"}
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
  def validate_entry(%{role: :persona_summary} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_persona_summary/1)
  end

  def validate_entry(%{role: :persona_sources} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_persona_sources/1)
  end

  @valid_by_existence_roles [
    :implementation,
    :test,
    :rule,
    :config,
    :bdd_spec,
    :qa_brief,
    :qa_result,
    :json,
    :review,
    :architecture,
    :integration,
    :agents_md,
    :project_knowledge,
    :hex_doc
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
  defp validate_persona_summary(content) do
    error =
      cond do
        String.trim(content) == "" ->
          "`summary.md` is empty"

        true ->
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
        Map.merge(entry, %{valid: true, validation_errors: nil})

      {:error, error} ->
        Map.merge(entry, %{valid: false, validation_errors: %{error: to_string(error)}})
    end
  rescue
    e ->
      Map.merge(entry, %{valid: false, validation_errors: %{error: Exception.message(e)}})
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
        &classify_docs/1,
        &classify_qa/1,
        &classify_config/1
      ],
      & &1.(path)
    )
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

    String.starts_with?(path, "test/support/") and
      (String.ends_with?(base, "_spex.ex") or
         String.ends_with?(base, "_test_boundary.ex") or
         String.ends_with?(base, "_spex_case.ex") or
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

  defp classify_docs(path) do
    classify_persona(path) ||
      if String.ends_with?(path, ".md"),
        do: Enum.find_value(doc_dir_roles(), &match_doc_dir(path, &1))
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

  # Only result_complete.md satisfies the :qa_result role. In-progress
  # (result.md) and archived failures (result_failed_<ts>.md) live on disk
  # but aren't role-tagged — qa_complete must not be satisfied by an
  # unfinished or failed run.
  defp match_qa_result?(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    String.starts_with?(path, qa_prefix) and
      Path.basename(path) == "result_complete.md"
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
    component_by_module = read_model.component_by_module

    # Ids parsed out of qa/spex paths are only trusted if the project actually
    # has such a story — a stale directory name must not link a file to it.
    story_by_id =
      entries
      |> extract_story_ids()
      |> Enum.filter(&MapSet.member?(read_model.story_ids, &1))
      |> Map.new(&{&1, &1})

    Enum.map(entries, fn entry ->
      {component_id, story_id} =
        owner_for(entry.path, entry.role, component_by_module, story_by_id)

      Map.merge(entry, %{component_id: component_id, story_id: story_id})
    end)
  end

  defp owner_for(path, role, component_by_module, _story_by_id)
       when role in [:implementation, :test, :spec] do
    module_name = path_to_module_name(path, role)
    {Map.get(component_by_module, module_name), nil}
  end

  defp owner_for(path, :bdd_spec, _component_by_module, story_by_id) do
    # test/spex/{story_id_and_title}/criterion_*_spex.exs → story
    story_id = extract_story_id_from_spex_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(path, role, _component_by_module, story_by_id)
       when role in [:qa_brief, :qa_result] do
    # .code_my_spec/qa/{story_id}/brief.md → story
    story_id = extract_story_id_from_qa_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(path, :review, component_by_module, _story_by_id) do
    # .code_my_spec/spec/metric_flow/integrations/design_review.md → MetricFlow.Integrations
    module_name =
      path
      |> String.replace_prefix(Paths.spec_dir() <> "/", "")
      |> Path.dirname()
      |> path_segments_to_module()

    {Map.get(component_by_module, module_name), nil}
  end

  defp owner_for(_path, _role, _component_by_module, _story_by_id), do: {nil, nil}

  # .code_my_spec/qa/440/brief.md → 440
  defp extract_story_id_from_qa_path(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    path
    |> String.replace_prefix(qa_prefix, "")
    |> String.split("/")
    |> hd()
    |> parse_integer()
  end

  # test/spex/424_user_registration.../criterion_*_spex.exs → 424
  defp extract_story_id_from_spex_path(path) do
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

  defp extract_story_ids(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case entry.role do
        :bdd_spec -> [extract_story_id_from_spex_path(entry.path)]
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
