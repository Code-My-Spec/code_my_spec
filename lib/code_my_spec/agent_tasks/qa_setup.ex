defmodule CodeMySpec.AgentTasks.QaSetup do
  @moduledoc """
  Produce the project-wide `qa_plan` document in the database.
  """

  alias CodeMySpec.Documents, as: DocumentParser
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Qa.Documents
  alias CodeMySpec.{ExecutionContexts, Paths}

  @doc_type "qa_plan"
  @scripts_dir Path.join(Paths.qa_dir(), "scripts")
  @router_glob "lib/*_web/router.ex"
  @existing_seeds_glob "priv/repo/qa*.exs"

  # ============================================================================
  # orchestrate — relevance signal for the requirement graph
  # ============================================================================

  def dispatch(_node) do
    "Produce the project-wide `qa_plan` document in the database. " <>
      "Probes every running endpoint (listening ports, auth pipelines, MCP " <>
      "transports) then writes the plan covering App Overview, Tools Registry, " <>
      "and Seed Strategy. Use when starting QA work and no plan exists, or " <>
      "when routers / seed scripts / auth surfaces have changed since the " <>
      "last plan."
  end

  # ============================================================================
  # Command — slim prompt that points at the workflow doc
  # ============================================================================

  @doc """
  Build the planning prompt. Discovers `lib/*_web/router.ex` files, lists
  existing QA seed scripts and helper scripts, and pulls the `qa_plan`
  document spec from the registry. Returns `{:ok, prompt}`.
  """
  def command(scope, _task) do
    env = CodeMySpec.AgentTasks.execution_context(scope)

    routers = list_routers(env)
    existing_plan = read_existing_plan(scope)
    existing_seeds = list_paths(env, @existing_seeds_glob)
    existing_scripts = list_paths(env, Path.join(@scripts_dir, "*"))

    doc_spec = DocumentSpecProjector.project_spec(@doc_type)

    prompt =
      build_prompt(
        routers,
        existing_plan,
        existing_seeds,
        existing_scripts,
        doc_spec
      )

    {:ok, prompt}
  end

  # ============================================================================
  # Evaluate the stored qa_plan document
  # ============================================================================

  @doc """
  Validate the stored document against the registered `qa_plan` document
  spec. Returns `{:ok, :valid}` or `{:ok, :invalid, feedback}`.
  """
  def evaluate(scope, _task) do
    case Documents.get(scope, "qa_plan") do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        case DocumentParser.create_dynamic_document(content, @doc_type) do
          {:ok, _} -> {:ok, :valid}
          {:error, reason} -> {:ok, :invalid, plan_feedback(nil, reason)}
        end

      {:ok, nil} ->
        {:ok, :invalid,
         plan_feedback(nil, "QA plan document not found. Write it with write_document.")}

      {:error, reason} ->
        {:ok, :invalid, "Could not read QA plan document: #{inspect(reason)}"}
    end
  end

  defp plan_feedback(_plan_path, reason) do
    spec = DocumentSpecProjector.project_spec(@doc_type)
    "#{reason}\n\n## QA Plan Format\n\n#{spec}"
  end

  # ============================================================================
  # Validation
  # ============================================================================

  # ============================================================================
  # Discovery
  # ============================================================================

  defp list_routers(env) do
    env
    |> ExecutionContexts.glob(@router_glob)
    |> Enum.sort()
    |> Enum.map(fn path ->
      case ExecutionContexts.read_file(env, path) do
        {:ok, content} -> {path, content}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp read_existing_plan(scope) do
    case Documents.get(scope, "qa_plan") do
      {:ok, %{content: content}} -> content
      _ -> nil
    end
  end

  defp list_paths(env, glob) do
    case ExecutionContexts.glob(env, glob) do
      paths when is_list(paths) -> Enum.sort(paths)
      _ -> []
    end
  end

  # ============================================================================
  # Prompt assembly. Static procedural detail lives in the framework knowledge
  # library at `qa_setup/workflow.md` (read via the `read_knowledge` MCP tool)
  # — pointed at via the playbook section rather than inlined here.
  # ============================================================================

  defp build_prompt(routers, existing_plan, existing_seeds, existing_scripts, doc_spec) do
    [
      header_section(),
      doc_spec_section(doc_spec),
      routers_section(routers),
      inventory_section(existing_seeds, existing_scripts),
      existing_plan_section(existing_plan),
      playbook_section()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp header_section do
    """
    # QA Setup: Infrastructure Planning

    Your job is to write the `qa_plan` document with `write_document` — a QA plan covering every running
    surface of this app: every web endpoint, every API pipeline, every MCP
    server, every hook URL. Real selectors. Real headers. Real seed paths.

    Multi-router apps (hosted UI + localhost CLI server, marketing site + app,
    etc.) are common. If the Router Files section below shows more than one
    router, the plan covers every one.

    Work in two phases: **Probe** then **Write**. Read the playbook below for
    the full protocol before doing either.\
    """
  end

  defp doc_spec_section(doc_spec) do
    """
    ## Document format

    Use `write_document` with `document_type: "qa_plan"` and the plan content.
    Read it with `read_document`. The validator rejects extra H2 sections and
    requires non-empty required sections.

    #{doc_spec}\
    """
  end

  defp routers_section([]) do
    """
    ## Router files

    No `#{@router_glob}` files found. Run `mix phx.routes` to enumerate routes
    by hand and document every pipeline + auth plug you find.\
    """
  end

  defp routers_section(routers) do
    formatted =
      Enum.map_join(routers, "\n\n", fn {path, content} ->
        """
        ### `#{path}`

        ```elixir
        #{content}
        ```\
        """
      end)

    """
    ## Router files (#{length(routers)} found)

    Every pipeline below maps to a row in your Tools Registry — pick the right
    tool for each (Vibium for `:browser`, curl for `:api`/JSON, MCP-aware
    client for `:mcp`).

    #{formatted}\
    """
  end

  defp inventory_section(seeds, scripts) do
    sections =
      [
        format_inventory("Existing seed scripts", @existing_seeds_glob, seeds),
        format_inventory("Existing helper scripts", "#{@scripts_dir}/*", scripts)
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> nil
      sections -> "## Inventory\n\n#{Enum.join(sections, "\n\n")}"
    end
  end

  defp format_inventory(_label, _glob, []), do: nil

  defp format_inventory(label, glob, paths) do
    list = Enum.map_join(paths, "\n", &"- `#{&1}`")
    "### #{label} (`#{glob}`)\n\n#{list}"
  end

  defp existing_plan_section(nil), do: nil

  defp existing_plan_section(_content) do
    """
    ## Existing plan — patch rather than rewrite

    A `qa_plan` document already exists. Read it with `read_document`. The playbook covers the
    idempotent-rerun procedure: diff against the Router Files and Inventory
    sections above, and edit only the sections that drifted. Preserve working
    scripts and credentials — the plan is institutional memory.\
    """
  end

  defp playbook_section do
    """
    ## Read the playbook

    Read these via the `read_knowledge` MCP tool before probing or writing:

    - `qa_setup/workflow.md` — full two-phase procedure (probe protocol
      with the 5 discovery steps, writing conventions, seed/auth script
      rules, idempotent-rerun procedure).
    - `qa-tooling.md` — tool selection (Vibium vs curl) and authentication
      patterns.
    - Per-tool cheat sheets under `qa-tooling/` (browse with
      `list_knowledge`, then read individual entries).\
    """
  end
end
