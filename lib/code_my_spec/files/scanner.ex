defmodule CodeMySpec.Files.Scanner do
  @moduledoc """
  Observes the filesystem and reports what it finds. The device half of file
  sync.

  Everything here needs the working copy: walking it, hashing it, reading file
  contents to decide whether a document is valid. None of it needs the database,
  and nothing it returns contains file content — validation happens here and
  only its verdict travels.

  `FileSync` turns these observations into File rows, links them to components
  and stories, and reconciles them against what is stored; that can run
  anywhere. Scanning has to be where the files are.

  The one thing scanning needs from the domain is a `ReadModel`, passed in
  rather than queried so this module holds no repo of its own.
  """

  alias CodeMySpec.BddSpecs.ContentCheck
  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.ComponentExtract
  alias CodeMySpec.Files.DependencyEvidence
  alias CodeMySpec.Paths

  # The subtrees a sync walks. Everything outside them is invisible to the
  # domain, which is what keeps a project's own deps/ and _build/ out of it.
  # The deploy roots (`bin`, `.github`, `config`, `rel`, `envs`, `Dockerfile`,
  # `.sops.yaml`, the plaintext env names) are here so `DeployBoilerplate`'s
  # manifest can be answered from rows; each is small and bounded.
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
    "mix.lock",
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

    `component_by_module` resolves a file path to its owning component.
    `strict?` selects whether document validation requires complete sections.

    Both path families name a story by its durable number —
    `.code_my_spec/qa/<number>/` and `test/spex/<number>_<slug>/` — and
    `story_ids_by_number` resolves it to the id File rows key on.

    `component_by_path` projects known module names *forward* into their
    conventional paths, which is exact; deriving a module from a path is not
    (`code_my_spec/git/cli` camelizes to `Git.Cli`, never `Git.CLI`). See
    `Components.ConventionalPaths`.

    `story_by_spec_path` is the one that does not guess: a criterion records
    which file is its spex, so a spex file's story is a lookup. The number
    parse survives only as the fallback for files nothing has claimed yet —
    it is wrong after a migration, because story ids are per-deployment.
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

  Returns `{:error, reason}` when the environment does not scan — never `[]`,
  which a caller cannot tell from an empty working copy and would answer by
  deleting every row.
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

  These are dropped by `stream_files/1`. An unclassified file never syncs, so
  the requirement that gates on it reports it missing while it sits on disk —
  which reads exactly like a dead file watcher. Most of what this returns is
  legitimately ignorable (test-support scaffolding, fixtures, page content);
  the point is that "cannot see my file" and "chose not to track it" stop
  looking the same.
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
  # `resolve_owners/2` prefers this over the module implied by the path, since
  # Phoenix puts `CoreComponents` under `components/` and `ErrorHTML` under
  # `controllers/`.
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
  not walk a working copy. Same contract as `observe/2`: the refusal must stay
  distinguishable from an empty tree.
  """
  @spec stream_files(Environments.Environment.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_files(env) do
    case Environments.stream_files(env, @sync_roots) do
      {:error, reason} -> {:error, reason}
      stream -> {:ok, classified(stream, env)}
    end
  end

  # The half of the walk that turns paths into entries. Shared with `observe/2`.
  defp classified(stream, env) do
    stream
    |> Stream.map(&classify/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn {path, role} -> stat_file(env, path, role) end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Validate a file entry based on its role.

  Component specs and design reviews are not parsed: components are records,
  so those files describe nothing and are valid by existence, like test files
  and the other tracked roles.
  """
  def validate_entry(entry, env, component_by_id, strict? \\ true)

  # Spex files are checked here, on the machine that has them: the server may
  # hold no working copy. Only the verdict travels; `ContentCheck` is pure so it
  # runs without a database or shipping content.
  def validate_entry(%{role: :bdd_spec} = entry, env, _component_by_id, _strict?) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        case ContentCheck.check(content, entry.path) do
          # The number rides in `data`, as `module_name` does for
          # implementations, so the server can bind the file to its criterion
          # without the harness knowing what criteria exist.
          {:ok, criterion} ->
            Map.merge(entry, %{
              valid: true,
              validation_errors: %{"data" => %{"criterion" => criterion}}
            })

          {:error, reason} ->
            Map.merge(entry, %{
              valid: false,
              validation_errors:
                %{"reason" => ContentCheck.describe(reason, entry.path)}
                |> put_named_criterion(ContentCheck.named_criterion(content, entry.path))
            })
        end

      {:error, reason} ->
        Map.merge(entry, %{
          valid: false,
          validation_errors: %{"reason" => "Read failed: #{inspect(reason)}"}
        })
    end
  end

  # Setup artifacts: each validator runs its per-concern checks and persists the
  # results into `validation_errors` keyed by concern. The Setup.* step decides
  # pass/fail by reading those keys, with no filesystem access.
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

  # Parsed against the registered `qa_plan` document spec at sync time, so the
  # requirement reads a verdict instead of a file.
  def validate_entry(%{role: :qa_plan} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_qa_plan(&1, entry.path))
  end

  # An integration spec's verdict, decided where the file is, so
  # `Requirements.QaIntegrationPlanChecker` never globs or reads over a harness
  # call on every graph computation. Facts rather than errors: a `pending` spec
  # is unfinished work, not a malformed document.
  def validate_entry(%{role: :integration} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_integration/1)
  end

  def validate_entry(%{role: :persona_summary} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_persona_summary/1)
  end

  def validate_entry(%{role: :persona_sources} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_persona_sources/1)
  end

  # Which required secret names an environment's encrypted file declares —
  # never their values, and never a decryption. SOPS's dotenv mode encrypts
  # values only, so key names are plaintext. Answered here, at sync time, so
  # `Provisioning.Steps.check_secrets/2` reads the verdict, not the file.
  def validate_entry(%{role: :encrypted_env} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_encrypted_env/1)
  end

  def validate_entry(%{role: :implementation} = entry, env, _component_by_id, _strict?) do
    # Valid because it is there. The scan also records the `defmodule` name and
    # whether it is an Ecto schema (the one type fact read from an
    # implementation — see `ComponentExtract.ecto_schema?/1`), so
    # `ComponentSync` never re-opens the file.
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        Map.merge(entry, %{
          valid: true,
          validation_errors: %{
            "errors" => %{},
            "data" => %{
              "module_name" => ComponentExtract.extract_defmodule(content),
              "ecto_schema" => ComponentExtract.ecto_schema?(content),
              "dependency_evidence" => DependencyEvidence.extract(content)
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
    :lockfile,
    :bdd_spec,
    :qa_brief,
    :qa_result,
    :qa_script,
    :json,
    :architecture,
    :credo_check,
    :integration,
    :agents_md,
    :project_knowledge,
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

  # Persona and QA-plan rules are decided once at sync and carried in
  # `validation_errors`, so a server with no working copy can read the verdict.
  # Two files share the `:qa_plan` role and are different documents: `plan.md`
  # parses as `qa_plan`, `journey_plan.md` as `qa_journey_plan`.
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

  # Every entry names something you can go back to: a URL, or a path in the
  # repo. No date is required — for an agent definition or a log observation
  # the locator is the reproducible part.
  defp validate_persona_sources(content) do
    entries = source_entries(content)
    invalid = Enum.find(entries, &(not locates_something?(&1)))

    error =
      cond do
        entries == [] ->
          "`sources.md` has no entries — expected one markdown list item per " <>
            "source, each naming a URL or a file path"

        invalid != nil ->
          "`sources.md` entry names no URL or file path: " <> String.slice(invalid, 0, 80)

        true ->
          nil
      end

    %{errors: %{sources: error}, data: %{entry_count: length(entries)}}
  end

  # One bullet is one entry even when it wraps, which is what markdown means by
  # a list item.
  defp source_entries(content) do
    content
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "- ") or String.starts_with?(trimmed, "* ") ->
          [trimmed | acc]

        # A continuation is an indented, non-blank line under an open bullet.
        # Anything flush-left — a heading, a paragraph, a blank — ends it.
        trimmed != "" and acc != [] and line != trimmed ->
          [current | rest] = acc
          [current <> " " <> trimmed | rest]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # A URL, or something path-shaped: segments joined by `/` ending in a file
  # extension. The extension is what keeps prose out — "and/or" has a slash and
  # names nothing.
  defp locates_something?(entry) do
    Regex.match?(~r{https?://\S+}, entry) or
      Regex.match?(~r{[\w.~-]+(?:/[\w.~-]+)+\.\w+}, entry)
  end

  # The two facts a requirement asks of an integration spec: where its verify
  # script is, and whether it has been verified. The index (`integrations.md`)
  # carries the same role but is a list, with nothing to record.
  defp validate_integration(content) do
    %{
      errors: %{},
      data: %{
        verify_script: verify_script_path(content),
        verified: verified_status?(content)
      }
    }
  end

  defp verify_script_path(content) do
    case Regex.run(~r/##\s*Verify Script\s*\n+`?([^\n`]+)`?/i, content) do
      [_, path] -> String.trim(path)
      _ -> nil
    end
  end

  # The body of the `## Status` section, anchored — a whole-document substring
  # match passes on "unverified" and on prose like "once verified".
  defp verified_status?(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^##\s*Status\s*$/i)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.starts_with?(&1, "##")))
    |> Enum.map_join(" ", &String.trim/1)
    |> String.trim()
    |> String.downcase()
    |> String.match?(~r/^verified\b/)
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

  # The exact key names `CodeMySpec.Provisioning.Steps.check_secrets/2` needs
  # before it will run a deploy. Literal here on purpose: a rename on one side
  # should fail loudly (a missing key reads as "not configured").
  @required_secret_keys ~w(SECRET_KEY_BASE DATABASE_URL)

  defp validate_encrypted_env(content) do
    present = Enum.filter(@required_secret_keys, &Regex.match?(~r/^#{&1}=/m, content))
    missing = @required_secret_keys -- present

    error =
      case missing do
        [] -> nil
        names -> "missing " <> Enum.join(names, ", ")
      end

    %{errors: %{required_secrets: error}, data: %{"present" => present, "missing" => missing}}
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

  @doc """
  Classify a relative path into a file role.

  Returns `{path, role}` or `nil` if the path doesn't match any known pattern.
  """
  @spec classify(String.t()) :: {String.t(), atom()} | nil
  def classify(path) do
    Enum.find_value(
      [
        &classify_setup_artifact/1,
        &classify_code/1,
        &classify_credo_check/1,
        &classify_docs/1,
        &classify_qa/1,
        &classify_config/1,
        &classify_encrypted_env/1,
        &classify_deploy_artifact/1
      ],
      & &1.(path)
    )
  end

  # `DeployBoilerplate`'s manifest. Walking is not enough: `classified/2`
  # drops anything `classify/1` returns nil for. Existence is all
  # `DeployBoilerplate.missing/2` asks of these, so one role covers them all.
  @deploy_artifact_dirs ~w(bin/ .github/ config/ rel/ envs/)
  @deploy_artifact_files ~w(Dockerfile .sops.yaml .env .env.local .env.production .env.schema)

  defp classify_deploy_artifact(path) do
    if path in @deploy_artifact_files or
         Enum.any?(@deploy_artifact_dirs, &String.starts_with?(path, &1)),
       do: {path, :deploy_artifact}
  end

  # The one deploy artifact whose content a check needs, not just its
  # existence — see `validate_encrypted_env/1`. Checked ahead of the general
  # `envs/` rule above so these two specific files get it instead.
  defp classify_encrypted_env(path) do
    if String.starts_with?(path, "envs/") and String.ends_with?(path, ".enc.env"),
      do: {path, :encrypted_env}
  end

  # Setup-time artifacts. Validated at sync time so the requirements graph
  # decides `project_setup` from rows instead of re-reading these files.
  defp classify_setup_artifact(path) do
    cond do
      path == "mix.exs" -> {path, :mix_exs}
      path == "mix.lock" -> {path, :lockfile}
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

    # The fixtures bridge `SpexBoundaryChecker` looks for: `classify_code/1`
    # claims only `_test.exs`/`_spex.exs` under test/, so it needs this.
    # `do_validate_test_support/3` treats an unrecognised basename as
    # valid-by-existence.
    String.starts_with?(path, "test/support/") and
      (String.ends_with?(base, "_spex.ex") or
         String.ends_with?(base, "_test_boundary.ex") or
         String.ends_with?(base, "_spex_case.ex") or
         String.ends_with?(base, "_spex_fixtures.ex") or
         base == "conn_case.ex" or
         base == "data_case.ex")
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
  # Framework knowledge is intentionally absent — it lives in
  # `priv/knowledge/` and `FrameworkKnowledgeReconciler` embeds it on boot.
  # Nothing under the project tree resolves to that role.
  defp doc_dir_roles do
    [
      {&Paths.rules_dir/0, :rule},
      {&Paths.architecture_dir/0, :architecture},
      {&Paths.integrations_dir/0, :integration},
      {&Paths.knowledge_dir/0, :project_knowledge}
    ]
  end

  # `.code_my_spec/credo_checks/**/*.ex[s]`, which neither `classify_code/1`
  # (`lib/`, `test/`) nor `classify_docs/1` (`.md`) claims. Both extensions: the
  # framework ships `checks.exs` beside the `.ex` checks.
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

  # `.code_my_spec/integrations.md` is a sibling of `integrations/`, so
  # `match_doc_dir/2` (trailing slash) never claims it.
  # `Requirements.QaIntegrationPlanChecker`'s `check_index/1` gates on it.
  defp exact_doc_role(path) do
    if path == Paths.integrations_index(), do: {path, :integration}
  end

  # `.code_my_spec/personas/<slug>/{summary,sources}.md`.
  #
  # Their own roles rather than a shared `:persona`, because each is validated
  # differently — the summary against a document schema, the sources against a
  # line format — and `PersonasChecker` reports them as separate gaps. Anything
  # else in the folder is unclassified.
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
      # The plans `qa_setup` and the journey requirements gate on.
      path in [Paths.qa_plan(), Paths.qa_journey_plan()] -> {path, :qa_plan}
      # The scripts the integration specs point at. The checker asserts each
      # named script exists, so an unclaimed script would not move the graph
      # fingerprint when created. `.code_my_spec/qa/summary.md` and
      # `design/design_system.html` are deliberately unclaimed: no graph
      # node reads them. See knowledge/platform, "File classification".
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
  # Checked before `match_qa_file?/2` so a script named `brief.md` is not taken
  # for a story brief.
  defp match_qa_script?(path) do
    String.starts_with?(path, Paths.qa_scripts_dir() <> "/")
  end

  # Only result_complete.md satisfies the :qa_result role. In-progress
  # (result.md) and archived failures (result_failed_<ts>.md) live on disk
  # but aren't role-tagged — qa_complete must not be satisfied by an
  # unfinished or failed run. `journey_result.md` is what `qa_journey_execute`
  # gates on. `ClassifiableArtifactsTest` enumerates the gated artifacts.
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
    Enum.map(entries, fn entry ->
      {component_id, story_id} =
        case recorded_story(entry, read_model.story_by_spec_path) do
          nil ->
            owner_for(entry, read_model)

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

  # Three sources, in descending order of how much they know:
  #
  # 1. The path, against components projected forward into their conventional
  #    paths. Exact.
  # 2. The module the file declares (Phoenix puts `CoreComponents` under
  #    `components/`). Populated only after `validate_entry/4`, which runs after
  #    this on the harness pass — harmless, because the server re-resolves on
  #    every manifest (`FileSync.reconcile/2`).
  # 3. A module name derived from the path — a guess that cannot be made
  #    correct (`Git.Cli` never matches `Git.CLI`). Last resort: wrong there
  #    costs an unowned file, not a wrong owner.
  #
  # See `Components.ConventionalPaths`.
  defp owner_for(entry, %ReadModel{} = read_model)
       when is_map_key(entry, :role) and
              entry.role in [:implementation, :test] do
    by_module = read_model.component_by_module

    component_id =
      Map.get(read_model.component_by_path, entry.path) ||
        Map.get(by_module, declared_module(entry)) ||
        Map.get(by_module, path_to_module_name(entry.path, entry.role))

    {component_id, nil}
  end

  # test/spex/{story_number_and_title}/criterion_*_spex.exs → story
  #
  # Through `story_ids_by_number`: the directory is named from the durable
  # number, and every File row keys on the primary key.
  defp owner_for(%{path: path, role: :bdd_spec}, %ReadModel{} = read_model) do
    story_number = extract_story_number_from_spex_path(path)
    {nil, Map.get(read_model.story_ids_by_number, story_number)}
  end

  # .code_my_spec/qa/{story_number}/brief.md → story, through the same number
  # map as spex. An unknown number resolves to nothing.
  defp owner_for(%{path: path, role: role}, %ReadModel{} = read_model)
       when role in [:qa_brief, :qa_result] do
    story_number = extract_story_number_from_qa_path(path)
    {nil, Map.get(read_model.story_ids_by_number, story_number)}
  end

  defp owner_for(_entry, %ReadModel{}), do: {nil, nil}

  # The `defmodule` the scan read out of the file, when it has been validated.
  # String keys because this arrives from the harness as JSON.
  defp declared_module(%{declared_module: name}) when is_binary(name) and name != "", do: name

  defp declared_module(%{validation_errors: %{"data" => %{"module_name" => name}}})
       when is_binary(name) and name != "",
       do: name

  defp declared_module(_entry), do: nil

  # .code_my_spec/qa/440/brief.md → 440
  defp extract_story_number_from_qa_path(path) do
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

  # The story a criterion says this file belongs to. Only for spex: a criterion
  # records its own file, so this is a join. `nil` when nothing has claimed the
  # path (a spex just written), which sends the entry to the number parse.
  defp recorded_story(%{role: :bdd_spec, path: path}, story_by_spec_path)
       when is_binary(path) do
    Map.get(story_by_spec_path, path)
  end

  defp recorded_story(_entry, _story_by_spec_path), do: nil

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

  defp put_named_criterion(errors, nil), do: errors
  defp put_named_criterion(errors, number), do: Map.put(errors, "data", %{"criterion" => number})
end
