defmodule CodeMySpec.TechnicalStrategyFixtures do
  @moduledoc """
  Seeds an `InMemoryEnvironment` with the filesystem state a technical
  strategy task inspects. Used by BDD specs for Story 80 (Architecture
  Decision Records).

  Additive — each helper writes one piece of state and can be composed.
  All writes go through the `Environments` API so the fixture works
  against any environment (memory, local, cli).

  ## Conventions

  - Realistic `mix.exs` mirrors the post-project-setup shape: a project
    block with `deps/0` listing the standard CodeMySpec stack. The
    prompt reads mix.exs raw and inlines it, so realism matters for
    specs that assert on what the agent sees.
  - Pre-existing ADR bodies include a sentinel string the spec asserts
    on to prove the file survived auto-write.
  - Helpers write ONLY the artifact they name. Nothing else. Scenarios
    compose the state they need.

  ## Related

  - `lib/code_my_spec/agent_tasks/technical_strategy.ex` — the agent
    task whose `command/2` inspects these artifacts and writes the
    pre-made ADRs.
  - `lib/code_my_spec/requirements/requirement_definition_data.ex` —
    `technical_strategy` requirement uses `:path_exists` on
    `.code_my_spec/architecture/decisions.md`.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @decisions_dir ".code_my_spec/architecture/decisions"
  @index_path ".code_my_spec/architecture/decisions.md"

  @doc "Directory where ADR files live."
  @spec decisions_dir() :: String.t()
  def decisions_dir, do: @decisions_dir

  @doc "Path of the decisions index file."
  @spec index_path() :: String.t()
  def index_path, do: @index_path

  @doc """
  Write a realistic mix.exs that mirrors the post-project-setup shape.

  The file lists the standard CodeMySpec stack so a spec exercising
  the "Current Dependencies" prompt section sees realistic content —
  not a stub the agent would never encounter in production.
  """
  @spec with_mix_exs(Environment.t()) :: :ok
  def with_mix_exs(env) do
    Environments.write_file(env, "mix.exs", """
    defmodule MyApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :my_app,
          version: "0.1.0",
          elixir: "~> 1.17",
          compilers: [:boundary, :spex] ++ Mix.compilers(),
          deps: deps()
        ]
      end

      def application do
        [mod: {MyApp.Application, []}, extra_applications: [:logger]]
      end

      defp deps do
        [
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 1.0"},
          {:ecto_sql, "~> 3.12"},
          {:postgrex, ">= 0.0.0"},
          {:swoosh, "~> 1.5"},
          {:dotenvy, "~> 1.0"},
          {:sexy_spex, "~> 0.1"},
          {:wallaby, "~> 0.30", only: :test},
          {:req_cassette, "~> 0.6", only: :test},
          {:credo, "~> 1.7", only: [:dev, :test]}
        ]
      end
    end
    """)
  end

  @doc """
  Write a pre-existing ADR file for `topic` whose content contains
  `marker` verbatim.

  Scenarios use the marker to prove the retrofit developer's ADR
  survived the auto-write pass. Default marker phrasing mirrors
  the shape of an ADR a human might have written by hand.
  """
  @spec with_custom_adr(Environment.t(), String.t(), String.t()) :: :ok
  def with_custom_adr(env, topic, marker) when is_binary(marker) do
    content = """
    # Custom decision for #{topic}

    ## Status
    Accepted

    ## Context
    #{marker}

    ## Decision
    Retain the existing choice — this ADR predates CodeMySpec adoption.
    """

    Environments.write_file(env, "#{@decisions_dir}/#{topic}.md", content)
  end

  @doc """
  Write a decisions index at `.code_my_spec/architecture/decisions.md`.

  The index is the artifact the technical_strategy requirement's
  `:path_exists` check gates on.
  """
  @spec with_decisions_index(Environment.t()) :: :ok
  def with_decisions_index(env) do
    Environments.write_file(env, @index_path, """
    # Architecture Decisions

    | Topic | Decision | Status |
    |---|---|---|
    | elixir | Use Elixir as the primary language | Accepted |
    | phoenix | Use Phoenix as the web framework | Accepted |
    | liveview | Use Phoenix LiveView for interactive UI | Accepted |
    """)
  end

  @doc """
  Read an ADR file for `topic`. Returns the content or `nil` if missing.

  Scenarios assert both existence and content preservation through this
  helper rather than poking the environment directly.
  """
  @spec read_adr(Environment.t(), String.t()) :: String.t() | nil
  def read_adr(env, topic) do
    case Environments.read_file(env, "#{@decisions_dir}/#{topic}.md") do
      {:ok, content} -> content
      _ -> nil
    end
  end

  @doc """
  Returns true if an ADR file exists for `topic`.
  """
  @spec adr_exists?(Environment.t(), String.t()) :: boolean()
  def adr_exists?(env, topic) do
    Environments.file_exists?(env, "#{@decisions_dir}/#{topic}.md") == true
  end
end
