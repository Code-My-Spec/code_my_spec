defmodule CodeMySpec.AgentTasks.QaSetup do
  @moduledoc """
  Infrastructure planner for QA testing.

  Analyzes the running app (routes, auth, config) and produces:
  1. **plan.md** — high-level QA plan with app overview, tools registry, and seed strategy
  2. **Executable tools** — shell scripts in `.code_my_spec/qa/scripts/` with auth baked in

  Designed to run repeatedly: after each story is implemented, QaSetup re-runs
  to update the plan and tools if the app has changed.

  Two main functions:
  - `command/3` — Builds prompt telling the planner agent to analyze the app and write/update plan.md
  - `evaluate/3` — Checks plan.md exists and has required sections
  """

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths}

  @required_sections ["app overview", "tools registry", "seed strategy"]

  @doc """
  Generate the planning prompt for the QA setup session.

  Reads the router file, checks for existing plan.md, and builds a prompt
  instructing the agent to analyze the app and produce plan.md with executable scripts.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, _session, _opts \\ []) do
    env = scope.environment

    app_name = derive_app_name(env)
    router_content = read_router(env, app_name)
    existing_plan = read_existing_plan(env)
    doc_spec = DocumentSpecProjector.project_spec("qa_plan")

    prompt = build_prompt(env, app_name, router_content, existing_plan, doc_spec)

    {:ok, prompt}
  end

  @doc """
  Validate that plan.md exists and contains the required sections.

  Returns:
  - `{:ok, :valid}` if plan.md exists with all required sections
  - `{:ok, :invalid, feedback}` if plan.md is missing or incomplete
  """
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment
    plan_path = Paths.qa_plan()

    case Environments.read_file(env, plan_path) do
      {:ok, content} ->
        with {:ok, :valid} <- validate_sections(content) do
          validate_start_script(env)
        end

      _ ->
        {:ok, :invalid, "QA plan not found at `#{plan_path}`. Write the plan and stop the session again."}
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp derive_app_name(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, app_name] -> app_name
          _ -> "my_app"
        end

      _ ->
        "my_app"
    end
  end

  defp read_router(env, app_name) do
    path = "lib/#{app_name}_web/router.ex"

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_existing_plan(env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(env, _app_name, router_content, existing_plan, doc_spec) do
    sections =
      [
        build_header(),
        build_doc_spec_section(doc_spec),
        build_router_section(router_content),
        build_existing_plan_section(existing_plan),
        build_scripts_section(env),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # QA Setup: Infrastructure Planning

    You are setting up QA infrastructure for this app. Your job is to analyze the running
    application — its routes, authentication mechanism, configuration — and produce a QA plan
    document and executable shell scripts that future QA agents can use.

    Read `.code_my_spec/framework/qa-tooling.md` for reference patterns on writing
    authenticated curl scripts, `.exs` seed scripts, and smoke tests.\
    """
  end

  defp build_doc_spec_section(doc_spec) do
    """
    ## Document Format

    Write the QA plan to `#{Paths.qa_plan()}` following this specification:

    #{doc_spec}\
    """
  end

  defp build_router_section(nil) do
    """
    ## Router

    Could not read the router file. Run `mix phx.routes` in the project directory
    to discover available routes, authentication pipelines, and live sessions.\
    """
  end

  defp build_router_section(router_content) do
    """
    ## Router

    Here is the app's router — analyze it for routes, auth pipelines, and live sessions:

    ```elixir
    #{router_content}
    ```\
    """
  end

  defp build_existing_plan_section(nil), do: nil

  defp build_existing_plan_section(_content) do
    """
    ## Existing Plan

    A QA plan already exists at `#{Paths.qa_plan()}`. Read it and update rather than
    starting from scratch. Preserve any working scripts and seed commands, and update
    sections that need changes based on the current app state.\
    """
  end

  @seeds_dir "priv/repo"
  @scripts_dir Path.join(Paths.qa_dir(), "scripts")

  defp build_scripts_section(env) do
    existing_scripts =
      case Environments.glob(env, Path.join(@scripts_dir, "*.sh")) do
        files when is_list(files) and files != [] ->
          file_list = Enum.map_join(files, "\n", &"- `#{&1}`")
          "\n\nExisting shell scripts:\n#{file_list}"

        _ ->
          ""
      end

    existing_seeds =
      case Environments.glob(env, Path.join(@seeds_dir, "qa_*.exs")) do
        files when is_list(files) and files != [] ->
          file_list = Enum.map_join(files, "\n", &"- `#{&1}`")
          "\n\nExisting seed scripts:\n#{file_list}"

        _ ->
          ""
      end

    """
    ## Scripts

    ### Seed data: `.exs` files in `#{@seeds_dir}/`

    Write QA seed scripts to `#{@seeds_dir}/` (e.g., `qa_seeds.exs`), run via `mix run #{@seeds_dir}/qa_seeds.exs`.
    Each `.exs` script boots the BEAM once and runs all its seed logic in one process.
    NEVER create a bash script that calls `mix run -e '...'` multiple times — each
    invocation boots the entire application from scratch, making it extremely slow.

    You can create multiple `.exs` scripts for different scenarios:
    - `qa_seeds.exs` — core entities (user, account, linked records)
    - `qa_seed_transactions.exs` — sample transactions for review testing
    - Or a single script if the app is simple enough

    Prefix QA seed files with `qa_` to distinguish them from the app's own `seeds.exs`.

    Each `.exs` script should:
    - Use the app's context modules to create entities (not raw Repo inserts)
    - Be idempotent — check for existing records before inserting
    - Print credentials and URLs at the end#{existing_seeds}

    ### Auth scripts: `.sh` files in `#{@scripts_dir}/`

    For HTTP auth helpers (e.g., `authenticated_curl.sh`), shell scripts are appropriate because
    they wrap curl with cookie/token handling. Make them `chmod +x`.#{existing_scripts}\
    """
  end

  defp build_instructions do
    """
    ## Instructions

    ### Step 1: Analyze the App

    1. Read the router to understand routes, pipelines, and live sessions
    2. Check `config/` for endpoint configuration (port, host, secret key base patterns)
    3. Identify the authentication mechanism (session-based? token? OAuth?)
    4. Look for Plug pipelines that enforce auth (e.g., `:require_authenticated_user`)

    ### Step 2: Discover Test Data Setup

    1. Look for factory modules (e.g., `test/support/fixtures/`, `test/support/factory.ex`)
    2. Check for seed files (`priv/repo/seeds.exs`)
    3. Identify context functions for creating users, accounts, and domain entities

    ### Step 3: Write Seed Scripts (`.exs` only — no bash)

    1. Write `.exs` seed scripts in `#{@seeds_dir}/` (prefixed with `qa_`)
    2. Seeds MUST be `.exs` files run via `mix run` — NEVER bash scripts
       A bash script that calls `mix run` multiple times boots the BEAM each time,
       is extremely slow, and can crash the running server
    3. Test that `mix run #{@seeds_dir}/qa_seeds.exs` works against the running app

    ### Step 4: Write Auth Scripts (`.sh`)

    1. Create `#{@scripts_dir}/` directory for shell scripts
    2. Write `authenticated_curl.sh` — wraps curl with login/cookie/token handling
    3. Make `.sh` scripts `chmod +x`
    4. Shell scripts are ONLY for HTTP auth helpers (curl wrappers), never for seeding data

    ### Step 5: Write `start-qa.sh`

    Create `#{Paths.qa_start_script()}` as the single entry point that handles seeds, auth,
    and any tool startup. QA agents run this script before every test session.

    The script should:
    - Run seed scripts (e.g., `mix run priv/repo/qa_seeds.exs`)
    - Handle authentication — common patterns:
      - **Vibium (Phoenix LiveView):** `vibium navigate` to the login URL, `vibium type` credentials, `vibium click` submit
      - **curl:** POST to the login endpoint and capture the session cookie/token
      - **mix run:** Create a token directly via context functions (e.g., `mix run -e 'MyApp.Accounts.create_user_api_token(...)'`)
    - Print credentials, URLs, and tokens at the end
    - Be idempotent — safe to run multiple times
    - Be `chmod +x`

    ### Step 6: Write the QA Plan

    Write `#{Paths.qa_plan()}` following the document specification above. Include:
    - **App Overview**: tech stack, auth mechanism, port/URL, key routes
    - **Tools Registry**: each testing tool with usage examples and auth handling
    - **Seed Strategy**: reference the `.exs` seed script with usage instructions

    When complete, stop the session so validation can check your work.\
    """
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_start_script(env) do
    script_path = Paths.qa_start_script()

    if Environments.file_exists?(env, script_path) do
      {:ok, :valid}
    else
      {:ok, :invalid,
       "`start-qa.sh` not found at `#{script_path}`. " <>
         "Write the start script and stop the session again."}
    end
  end

  defp validate_sections(content) do
    content_lower = String.downcase(content)

    missing =
      Enum.reject(@required_sections, fn section ->
        String.contains?(content_lower, "## #{section}")
      end)

    case missing do
      [] ->
        {:ok, :valid}

      sections ->
        section_list = Enum.map_join(sections, ", ", &"`## #{title_case(&1)}`")

        {:ok, :invalid,
         "QA plan is missing required section(s): #{section_list}. Update the plan and stop the session again."}
    end
  end

  defp title_case(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
