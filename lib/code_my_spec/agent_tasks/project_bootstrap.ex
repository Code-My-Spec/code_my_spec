defmodule CodeMySpec.AgentTasks.ProjectBootstrap do
  @moduledoc """
  Agent task for bootstrapping the project after technology decisions are finalized.

  Reads the decisions index and knowledge base, then implements each decision:
  adds libraries, configures them, sets up Dotenvy with environment files,
  collects user secrets, and writes smoke tests that call real APIs and record
  cassettes. The preferred pattern for external integrations is to write minimal
  Req-based API client modules and use req_cassette to record calls.

  Prerequisite: `topics_researched` must be satisfied (all decisions made and researched).
  """

  require Logger

  alias CodeMySpec.{Environments, Paths}

  @cassettes_dir "test/fixtures/cassettes"

  @doc """
  Generate the bootstrap prompt for the project setup session.

  Returns `{:ok, prompt_text}`.
  """
  @spec command(CodeMySpec.Users.Scope.t(), map(), keyword()) :: {:ok, String.t()}
  def command(scope, _session, _opts \\ []) do
    env = scope.environment
    project = scope.active_project

    decisions_index = read_decisions_index(env)
    adrs = read_adrs(env)
    mix_exs = read_mix_exs(env)
    env_example = read_env_example(env)
    env_file_exists = Environments.file_exists?(env, ".env") == true
    cassettes = list_cassettes(env)
    knowledge_entries = read_knowledge_entries(env, adrs)

    prompt =
      build_prompt(
        project,
        decisions_index,
        adrs,
        mix_exs,
        env_example,
        env_file_exists,
        cassettes,
        knowledge_entries
      )

    {:ok, prompt}
  end

  @doc """
  Validate the project is fully bootstrapped.

  Checks only deterministic, verifiable artifacts:
  1. `.env.example` exists and is non-empty
  2. Dotenvy configured in `runtime.exs` (contains `Dotenvy.source`)
  3. `.env` is listed in `.gitignore`
  4. `test/smoke_test.exs` exists
  5. Project compiles (via `System.cmd` if cwd is available)

  Returns `{:ok, :valid}` if all pass, or `{:ok, :invalid, feedback}` with
  actionable items.
  """
  @spec evaluate(CodeMySpec.Users.Scope.t(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    failures = []

    failures = check_env_example(env, failures)
    failures = check_dotenvy_configured(env, failures)
    failures = check_env_gitignored(env, failures)
    failures = check_smoke_test_exists(env, failures)
    failures = check_compilation(env, failures)

    Logger.info("[ProjectBootstrap] evaluate: #{length(failures)} failures")

    if Enum.empty?(failures) do
      {:ok, :valid}
    else
      feedback = build_feedback(failures)
      {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp read_decisions_index(env) do
    case Environments.read_file(env, Paths.decisions_index()) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_adrs(env) do
    case Environments.glob(env, Paths.decisions_glob()) do
      files when is_list(files) -> Enum.flat_map(files, &read_adr(env, &1))
      _ -> []
    end
  end

  defp read_adr(env, file) do
    relative = relative_path(file, env.cwd)

    case Environments.read_file(env, relative) do
      {:ok, content} -> [{Path.basename(file, ".md"), content}]
      _ -> []
    end
  end

  defp read_mix_exs(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_env_example(env) do
    case Environments.read_file(env, ".env.example") do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp list_cassettes(env) do
    case Environments.glob(env, "#{@cassettes_dir}/**/*.json") do
      files when is_list(files) -> Enum.map(files, fn f -> Path.basename(f, ".json") end)
      _ -> []
    end
  end

  defp read_knowledge_entries(env, adrs) do
    adrs
    |> Enum.map(fn {topic, _content} -> topic end)
    |> Enum.flat_map(&read_knowledge_for_topic(env, &1))
  end

  defp read_knowledge_for_topic(env, topic) do
    glob_pattern = Paths.knowledge_topic_glob(topic)

    case Environments.glob(env, glob_pattern) do
      files when is_list(files) and files != [] ->
        Enum.flat_map(files, &read_knowledge_file(env, topic, &1))

      _ ->
        []
    end
  end

  defp read_knowledge_file(env, topic, file) do
    relative = relative_path(file, env.cwd)

    case Environments.read_file(env, relative) do
      {:ok, content} -> [{topic, file, content}]
      _ -> []
    end
  end

  defp relative_path(absolute_path, nil), do: absolute_path

  defp relative_path(absolute_path, cwd) do
    case String.split(absolute_path, cwd <> "/", parts: 2) do
      [_, relative] -> relative
      _ -> absolute_path
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(
         project,
         decisions_index,
         adrs,
         mix_exs,
         env_example,
         env_file_exists,
         cassettes,
         knowledge_entries
       ) do
    sections =
      [
        build_header(project),
        build_decisions_section(decisions_index, adrs),
        build_current_state_section(mix_exs, env_example, env_file_exists, cassettes),
        build_knowledge_section(knowledge_entries),
        build_framework_section(),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header(project) do
    """
    # Project Bootstrap Session

    You are bootstrapping the **#{project.name}** project.

    Your goal is to implement all decided technologies: add dependencies, configure
    them, set up environment management with Dotenvy, collect required secrets,
    write Req-based API clients, and create smoke tests that record cassettes for
    every external integration.
    """
    |> String.trim_trailing()
  end

  defp build_decisions_section(nil, []), do: nil

  defp build_decisions_section(decisions_index, adrs) do
    index_section =
      if decisions_index do
        """
        ## Decisions Index

        #{decisions_index}
        """
        |> String.trim_trailing()
      end

    adr_section =
      if adrs != [] do
        adr_content =
          Enum.map_join(adrs, "\n\n", fn {topic, content} ->
            """
            ### #{topic}

            #{content}
            """
            |> String.trim_trailing()
          end)

        """
        ## Decision Records

        #{adr_content}
        """
        |> String.trim_trailing()
      end

    [index_section, adr_section]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp build_current_state_section(mix_exs, env_example, env_file_exists, cassettes) do
    parts = []

    parts =
      if mix_exs do
        [
          """
          ### Current Dependencies (mix.exs)

          ```elixir
          #{mix_exs}
          ```
          """
          |> String.trim_trailing()
          | parts
        ]
      else
        parts
      end

    parts =
      if env_example do
        [
          """
          ### Existing .env.example

          ```
          #{env_example}
          ```
          """
          |> String.trim_trailing()
          | parts
        ]
      else
        parts
      end

    parts =
      if env_file_exists do
        ["- `.env` file already exists" | parts]
      else
        parts
      end

    parts =
      if cassettes != [] do
        cassette_list = Enum.map_join(cassettes, "\n", &"- `#{&1}`")

        [
          """
          ### Existing Cassette Recordings

          The following cassettes already exist — do not re-record them:

          #{cassette_list}
          """
          |> String.trim_trailing()
          | parts
        ]
      else
        parts
      end

    if parts == [] do
      nil
    else
      content = parts |> Enum.reverse() |> Enum.join("\n\n")

      """
      ## Current State

      #{content}
      """
      |> String.trim_trailing()
    end
  end

  defp build_knowledge_section([]), do: nil

  defp build_knowledge_section(knowledge_entries) do
    entries =
      Enum.map_join(knowledge_entries, "\n\n", fn {topic, _file, content} ->
        """
        ### Knowledge: #{topic}

        #{content}
        """
        |> String.trim_trailing()
      end)

    """
    ## Research Knowledge

    The following knowledge entries were gathered during the research phase. Use them
    as authoritative guides when implementing each integration.

    #{entries}
    """
    |> String.trim_trailing()
  end

  defp build_framework_section do
    """
    ## Framework References

    Standard stack guides are available in `#{Paths.framework_dir()}/`. Consult them for:

    - Dotenvy setup and `.env` file conventions
    - Req HTTP client patterns and `req_cassette` recording strategy
    - Phoenix LiveView component patterns
    - Cloudflare tunnel management via the `client_utils` local dependency

    The `client_utils` local dep provides shared utilities including Cloudflare tunnel
    management. Add it to your `mix.exs` deps if any integration requires tunneling.
    """
    |> String.trim_trailing()
  end

  defp build_instructions do
    """
    ## Instructions

    Work through each step in order. Stop only when all steps are complete.

    ### Step 1: Add Dependencies

    Add all decided libraries to `mix.exs` and run `mix deps.get`. Check the
    Current Dependencies section to avoid duplicating already-installed deps.
    Note: `client_utils` is a local dependency providing Cloudflare tunnel management
    and other shared utilities — reference it with `{:client_utils, path: "../client_utils"}`.

    ### Step 2: Configure Dotenvy

    Set up `config/runtime.exs` to load `.env` files via Dotenvy:

    ```elixir
    import Config

    Dotenvy.source([".env", ".env." <> config_env()])

    config :my_app, :some_key, System.fetch_env!("SOME_KEY")
    ```

    Create `.env.example` listing every required environment variable with a
    description of what it is and where to get it. Ensure `.env` is added to `.gitignore`.

    ### Step 3: Collect Secrets

    For each external integration decided, identify the required API keys and credentials.
    Ask the user for each secret value individually. Write all provided values to `.env`.

    ### Step 4: Configure Libraries

    Add configuration entries to the appropriate `config/*.exs` files. Reference
    environment variables via `System.get_env/1` or `System.fetch_env!/1` for secrets.

    ### Step 5: Wire Up Application

    Update `lib/{app}/application.ex` to add any required workers or supervisors to
    the supervision tree (e.g., Finch pools, background job processors).

    ### Step 6: Write API Clients

    For each external integration, write a minimal Req-based API client module at
    `lib/{app}/clients/{service}.ex`. Use this pattern:

    ```elixir
    defmodule MyApp.Clients.Stripe do
      @base_url "https://api.stripe.com/v1"

      def client do
        Req.new(
          base_url: @base_url,
          auth: {:bearer, System.fetch_env!("STRIPE_SECRET_KEY")}
        )
      end

      def list_products do
        case Req.get(client(), url: "/products") do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, response} -> {:error, response}
          {:error, reason} -> {:error, reason}
        end
      end
    end
    ```

    Prefer Req over lower-level clients (Finch, Hackney, HTTPoison).

    ### Step 7: Design Recording Strategy

    For each API client, decide which HTTP calls to record as cassettes. Use
    `req_cassette` for all Req-based clients. For any legacy ExVCR-based dependencies,
    use `ExVCR.Mock` with the appropriate adapter. Document the cassette naming
    convention: `smoke_{service}_{operation}`.

    ### Step 8: Write Smoke Tests

    Write `test/smoke_test.exs` exercising each API client with `@moduletag :smoke`.
    Use `req_cassette` to record real API calls on the first run. These recordings
    become the canonical examples for how all future tests handle external calls:

    ```elixir
    defmodule MyApp.SmokeTest do
      use ExUnit.Case
      @moduletag :smoke

      test "stripe products endpoint" do
        ReqCassette.use("smoke_stripe_list_products") do
          assert {:ok, _products} = MyApp.Clients.Stripe.list_products()
        end
      end
    end
    ```

    ### Step 9: Run Smoke Tests

    Execute `mix test test/smoke_test.exs` to generate cassette recordings and verify
    all tests pass. Check the Existing Cassette Recordings section to avoid re-recording
    cassettes that already exist.

    ### Step 10: Stop

    Stop the session so validation can check that all bootstrap artifacts are in place.
    """
    |> String.trim_trailing()
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  defp check_env_example(env, failures) do
    case Environments.read_file(env, ".env.example") do
      {:ok, content} when content != "" ->
        failures

      {:ok, _empty} ->
        ["`.env.example` exists but is empty — add all required environment variables with descriptions" | failures]

      _ ->
        ["`.env.example` is missing — create it listing all required environment variables with descriptions" | failures]
    end
  end

  defp check_dotenvy_configured(env, failures) do
    case Environments.read_file(env, "config/runtime.exs") do
      {:ok, content} ->
        if String.contains?(content, "Dotenvy.source") or
             String.contains?(content, "Dotenvy.source!") do
          failures
        else
          ["Dotenvy is not configured in `config/runtime.exs` — add `Dotenvy.source([\".env\", ...])` to load environment files" | failures]
        end

      _ ->
        ["Dotenvy is not configured — `config/runtime.exs` does not exist; create it and add `Dotenvy.source([\".env\", ...])` calls" | failures]
    end
  end

  defp check_env_gitignored(env, failures) do
    case Environments.read_file(env, ".gitignore") do
      {:ok, content} -> check_env_in_gitignore_content(content, failures)
      _ -> ["`.gitignore` is missing — create it and add `.env` to prevent secrets from being committed" | failures]
    end
  end

  defp check_env_in_gitignore_content(content, failures) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    if Enum.any?(lines, fn line -> line == ".env" or String.starts_with?(line, ".env") end) do
      failures
    else
      ["`.env` is not listed in `.gitignore` — add `.env` to prevent secrets from being committed" | failures]
    end
  end

  defp check_smoke_test_exists(env, failures) do
    if Environments.file_exists?(env, "test/smoke_test.exs") == true do
      failures
    else
      ["`test/smoke_test.exs` (smoke_test) is missing — write smoke tests exercising each API client" | failures]
    end
  end

  defp check_compilation(env, failures) do
    cwd = env.cwd

    cond do
      is_nil(cwd) -> failures
      not File.exists?(cwd) -> failures
      not File.exists?(Path.join(cwd, "mix.exs")) -> failures
      true -> run_compilation(cwd, failures)
    end
  end

  defp run_compilation(cwd, failures) do
    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        failures

      {output, _exit_code} ->
        Logger.warning("[ProjectBootstrap] Compilation failed: #{output}")
        ["Project fails to compile — fix all compilation errors before continuing:\n#{output}" | failures]
    end
  end

  defp build_feedback(failures) do
    items =
      failures
      |> Enum.reverse()
      |> Enum.map_join("\n", &"- #{&1}")

    """
    Bootstrap is incomplete. Address the following:

    #{items}

    Fix these issues and stop the session again for re-validation.
    """
    |> String.trim_trailing()
  end
end
