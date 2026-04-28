defmodule CodeMySpec.AgentTasks.QaSetup do
  @moduledoc """
  Infrastructure planner for QA testing.

  Produces `.code_my_spec/qa/plan.md` — a plan covering EVERY running surface
  of the app (browser pipelines, API pipelines, MCP servers, hook endpoints)
  with concrete tooling, real selectors, and a per-Repo seed strategy.

  ## Multi-router awareness

  Many Phoenix apps ship more than one endpoint in a single OTP release —
  for example a hosted SaaS UI on one port plus a localhost-only CLI server
  on another. `command/2` globs every `lib/*_web/router.ex` it can find and
  hands them all to the agent. Plan covers all of them or it's wrong.

  ## Probe-then-write

  Reading config files isn't enough — Phoenix's compile-time `:url`, OAuth
  issuer config, and live_session gating only show their real behavior when
  you hit them. The prompt walks the agent through a discovery phase BEFORE
  writing the plan: list listening ports, hit each pipeline once, map the
  login pages, follow OAuth discovery, identify the MCP transport.

  ## Validation

  `evaluate/2` parses the plan against the registered `qa_plan` document
  type via `Documents.create_dynamic_document/2`. That gives structured
  feedback (missing sections, empty sections, unrecognised H2 headers) the
  agent can act on. Bare H2 presence is not enough — sections must have
  content.

  ## Idempotent re-runs

  When a plan already exists, the prompt asks the agent to diff it against
  current routers + inventory and patch sections rather than rewrite from
  scratch. Working scripts and credentials are preserved.
  """

  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths}

  @doc_type "qa_plan"
  @scripts_dir Path.join(Paths.qa_dir(), "scripts")
  @seeds_dir "priv/repo"
  @framework_qa_dir ".code_my_spec/framework/qa-tooling"
  @router_glob "lib/*_web/router.ex"
  @existing_seeds_glob "priv/repo/qa*.exs"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build the planning prompt.

  Discovers all `lib/*_web/router.ex` files, lists existing QA seed scripts
  and helper scripts, and pulls the `qa_plan` document spec from the
  registry. Returns `{:ok, prompt}`.
  """
  def command(scope, _task) do
    env = scope.environment

    routers = list_routers(env)
    existing_plan = read_existing_plan(env)
    existing_seeds = list_paths(env, @existing_seeds_glob)
    existing_scripts = list_paths(env, Path.join(@scripts_dir, "*"))
    knowledge_refs = list_paths(env, Path.join(@framework_qa_dir, "*"))

    doc_spec = DocumentSpecProjector.project_spec(@doc_type)

    prompt =
      build_prompt(
        routers,
        existing_plan,
        existing_seeds,
        existing_scripts,
        knowledge_refs,
        doc_spec
      )

    {:ok, prompt}
  end

  @doc """
  Validate `plan.md` by parsing it against the registered `qa_plan`
  document spec. Returns `{:ok, :valid}` or `{:ok, :invalid, feedback}`.
  """
  def evaluate(scope, _task) do
    env = scope.environment
    plan_path = Paths.qa_plan()

    case Environments.read_file(env, plan_path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        validate_content(plan_path, content)

      _ ->
        spec = DocumentSpecProjector.project_spec(@doc_type)

        {:ok, :invalid,
         "QA plan not found at `#{plan_path}`. Write the plan and stop the session again.\n\n## QA Plan Format\n\n#{spec}"}
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_content(plan_path, content) do
    case Documents.create_dynamic_document(content, @doc_type) do
      {:ok, _document} ->
        {:ok, :valid}

      {:error, reason} ->
        spec = DocumentSpecProjector.project_spec(@doc_type)
        friendly = translate_error(reason)

        {:ok, :invalid,
         "QA plan at `#{plan_path}` is #{friendly}. Update the plan and stop the session again.\n\n## QA Plan Format\n\n#{spec}"}
    end
  end

  defp translate_error("Missing required sections: " <> sections) do
    formatted =
      sections
      |> String.split(", ")
      |> Enum.map_join(", ", &"`## #{title_case(&1)}`")

    "missing required section(s): #{formatted}"
  end

  defp translate_error("Empty required sections: " <> sections) do
    formatted =
      sections
      |> String.split(", ")
      |> Enum.map_join(", ", &"`## #{title_case(&1)}`")

    "missing content under required section(s): #{formatted}"
  end

  defp translate_error(reason), do: "invalid: #{reason}"

  defp title_case(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # ============================================================================
  # Discovery
  # ============================================================================

  defp list_routers(env) do
    env
    |> Environments.glob(@router_glob)
    |> Enum.sort()
    |> Enum.map(fn path ->
      case Environments.read_file(env, path) do
        {:ok, content} -> {path, content}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp read_existing_plan(env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  defp list_paths(env, glob) do
    case Environments.glob(env, glob) do
      paths when is_list(paths) -> Enum.sort(paths)
      _ -> []
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(routers, existing_plan, existing_seeds, existing_scripts, knowledge_refs, doc_spec) do
    [
      build_header(),
      build_doc_spec_section(doc_spec),
      build_routers_section(routers),
      build_inventory_section(existing_seeds, existing_scripts, knowledge_refs),
      build_existing_plan_section(existing_plan),
      build_probe_section(),
      build_writing_section()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_header do
    """
    # QA Setup: Infrastructure Planning

    Your job is to write `#{Paths.qa_plan()}` — a QA plan covering every running
    surface of this app: every web endpoint, every API pipeline, every MCP
    server, every hook URL. Real selectors. Real headers. Real seed paths.

    Apps that ship multiple endpoints in one OTP release are common
    (hosted UI + localhost CLI server, marketing site + app, etc.). If the
    Router Files section below shows more than one router, that's the truth
    — your plan covers every one.

    Work in two phases:

    1. **Probe.** Run the discovery commands in the Probe section below.
       Hit every listening port, map the login pages, follow OAuth
       discovery, time one curl per pipeline. Cheap, mechanical, fast.
    2. **Write.** Then produce `plan.md` drawing only on what you observed.\
    """
  end

  defp build_doc_spec_section(doc_spec) do
    """
    ## Document Format

    Write the QA plan at `#{Paths.qa_plan()}` matching this spec exactly.
    The validator parses it as a `qa_plan` document — extra H2 sections are
    rejected, and required sections must be non-empty.

    #{doc_spec}\
    """
  end

  defp build_routers_section([]) do
    """
    ## Router Files

    No `#{@router_glob}` files found. Run `mix phx.routes` to enumerate
    routes by hand and document every pipeline + auth plug you find.\
    """
  end

  defp build_routers_section(routers) do
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
    ## Router Files (#{length(routers)} found)

    Every pipeline below maps to a row in your Tools Registry — pick the
    right tool for each (Vibium for `:browser`, curl for `:api`/JSON,
    MCP-aware client for `:mcp`).

    #{formatted}\
    """
  end

  defp build_inventory_section(seeds, scripts, knowledge) do
    sections =
      [
        format_inventory("Existing seed scripts", @existing_seeds_glob, seeds),
        format_inventory("Existing helper scripts", "#{@scripts_dir}/*", scripts),
        format_inventory("Available QA tooling cheat sheets", "#{@framework_qa_dir}/*", knowledge)
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

  defp build_existing_plan_section(nil), do: nil

  defp build_existing_plan_section(_content) do
    """
    ## Existing Plan — update rather than rewrite

    A plan already exists at `#{Paths.qa_plan()}`. Read it, diff it against
    the current routers and inventory above, and edit only the sections
    that drifted:

    - **App Overview** — new endpoints, ports, or auth pipelines?
    - **Tools Registry** — new MCP servers, new pipelines, broken commands?
    - **Seed Strategy** — new seed scripts, removed ones, schema changes?
    - **System Issues** — append anything you discover; don't delete
      entries unless the issue is genuinely fixed.

    Preserve working scripts and credentials.\
    """
  end

  defp build_probe_section do
    """
    ## Probe (run these BEFORE writing)

    ### 1. What's actually listening

    ```
    lsof -i -P -n | grep LISTEN
    ```

    Every loopback port the running app exposes deserves a row in the
    Tools Registry. Note the PID — multiple ports under one PID means one
    OTP release with multiple endpoints (very common).

    ### 2. Reach each port over HTTP

    For every listening port, hit `/`, `/health` (if it exists), and
    `/.well-known/oauth-authorization-server` (MCP-aware apps expose this
    even when they aren't fully OAuth). Record the response codes and any
    JSON returned.

    ```
    curl -sS -o /dev/null -w "%{http_code}\\n" http://127.0.0.1:<port>/
    curl -sS http://127.0.0.1:<port>/.well-known/oauth-authorization-server
    ```

    Watch for **issuer mismatch**: dev configs sometimes return a
    production hostname for OAuth metadata, which means minting bearer
    tokens locally requires a tunnel — note this in System Issues.

    ### 3. Map auth surfaces

    - **Browser pipelines.** Open `/users/log-in` (or whatever the app
      uses) in Vibium and call `browser_map`. Phoenix forms typically use
      `name="user[email]"`, NOT `id="login_email"` — document the REAL
      selectors. If multiple login forms render on one page (magic-link +
      password is common), document each.
    - **API pipelines.** Try one curl with no auth, capture the
      challenge. Note whether it's `X-Api-Key`, `Authorization: Bearer`,
      session cookie, or per-request scope (e.g. `X-Working-Dir`).
    - **MCP / SSE pipelines.** POST `initialize` and read the response
      headers. Anubis Streamable HTTP returns `mcp-session-id` plus
      `text/event-stream` for the body, then **subsequent `tools/call`
      requests come back as `202 Accepted` with the actual response
      delivered over the original init stream**. Plain one-shot curl WILL
      NOT work for tool calls. Either use the agent's MCP client tools or
      `mix test` against the server modules — document this either way.

    ### 4. Identify Repos and DB targets

    ```
    grep -rn "use Ecto.Repo\\|Ecto.Adapters" config/ lib/
    ```

    If the app has multiple env-conditional adapters (e.g. `:dev` →
    Postgres, `:dev_cli` → SQLite) or multiple Repos, plan a seed script
    per target. Show the right `MIX_ENV=…` invocation.

    ### 5. Verify Vibium screenshot landing dir

    `browser_screenshot { filename: "x/y.png" }` ignores the directory
    portion on at least some Vibium builds — files land in
    `~/Pictures/Vibium/<basename>`. Verify on this box and document the
    actual destination.\
    """
  end

  defp build_writing_section do
    """
    ## Writing the Plan

    ### Required sections (non-empty, validated)

    - **App Overview** — endpoints, ports, pipelines, auth model. Use a
      table when there's more than one endpoint.
    - **Tools Registry** — for each tool (Vibium MCP, curl, mix run, iex):
      when to use it, real example commands, ACTUAL selectors / headers /
      paths from the probe.
    - **Seed Strategy** — for each Repo / DB target, the file path, the
      `mix run` (or `MIX_ENV=… mix run`) command, and the credentials it
      prints. If a seed file already shows up in the Inventory, reference
      it; don't promise a duplicate.

    ### Strongly recommended

    - **System Issues** — anything that took >5 min to figure out goes
      here. Examples: 'OAuth discovery returns prod hostname on dev box',
      'Vibium screenshot writes to ~/Pictures/Vibium ignoring path',
      'Anubis MCP requires SSE-aware client, plain curl gives 202'.
      Future QA agents read this section first.

    ### Seed scripts (`.exs` only — no bash loops)

    Write QA seed scripts to `#{@seeds_dir}/` prefixed with `qa_` (e.g.
    `qa_seeds.exs`). Run via `mix run #{@seeds_dir}/qa_seeds.exs`. Each
    `.exs` boots the BEAM once and runs all logic in-process — NEVER write
    a bash script that loops `mix run -e '…'` per entity (cold-boots the
    BEAM each time, extremely slow).

    Each seed script should:
    - Use the app's context modules (`register_user`, `create_account`,
      etc.) — not raw `Repo.insert_all` — so changesets fire.
    - Be idempotent — check for existing records before inserting.
    - Print credentials and URLs at the end.

    For multi-Repo apps, write one script per target: e.g. `qa_seeds.exs`
    for the server Repo, `cli_qa_seeds.exs` for the CLI / SQLite Repo.

    ### Auth scripts (`.sh` files in `#{@scripts_dir}/`)

    Write a `.sh` wrapper ONLY for an auth model you confirmed works via
    curl during probing. Common pattern: `authenticated_curl.sh` adds the
    `X-Api-Key` or `Authorization: Bearer …` header for every call.

    - Single-line curl. NEVER multi-line, heredoc, or backslash-continued.
      See `#{@framework_qa_dir}/curl.md` for patterns.
    - `chmod +x` the file.
    - Don't write wrappers for browser sessions — that's Vibium's job.
    - Don't write wrappers for MCP transports — see Probe step 3.

    ### Stop and validate

    When done, stop the session. The validator parses your plan against
    the `qa_plan` document spec — extra H2 sections fail; required sections
    with empty bodies fail. Re-run probes if validation surfaces a
    contradiction with reality.\
    """
  end
end
