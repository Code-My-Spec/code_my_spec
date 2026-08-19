defmodule Mix.Tasks.Cms.Seed do
  @shortdoc "Run a seed script against the database without booting the endpoint"

  @moduledoc """
  Run a seed script with the database up and nothing else.

      mix cms.seed priv/repo/qa_seeds.exs
      mix cms.seed priv/repo/qa_739_seed.exs

  ## Why this exists

  `mix run priv/repo/<seed>.exs` boots the whole application, which binds the
  endpoint. On a machine where the dev server is already on :4000 — the ordinary
  case, since seeding is something you do *for* a running server — that dies:

      ** (Mix) Could not start application code_my_spec: … failed to start child:
         {Bandit, …} ** (EXIT) :eaddrinuse

  Nothing in that message mentions seeds, ports, or the running server, and the
  seed it was asked to run never executes. Every QA agent that meets it works
  around it privately: eight of the nine scripts under `priv/repo/` end up
  needing the same four-line preamble to start Ecto by hand, and the ninth was
  written after paying for the lesson.

  So the preamble belongs here, once, instead of in every script.

  ## What it starts

  `:ecto_sql`, `:postgrex`, the Vault (seeds touch encrypted columns), the Repo
  on a small quiet pool, and PubSub — because contexts broadcast on write, and a
  seed that goes through a context rather than writing rows by hand is the
  better kind. No endpoint, no web supervision tree.
  A seed that genuinely needs more can start it itself; that is a smaller
  surprise than a seed that cannot run at all.

  Config is loaded via `app.config` rather than `app.start`, so `runtime.exs`
  has run and `DATABASE_URL` and friends resolve exactly as they would for the
  app — without anything being supervised.

  ## What it does not do

  It does not pick a port, because it does not open one. An earlier suggestion
  was to run the seed on a different port; that works and leaves the seed
  holding an endpoint it has no use for. Not binding anything is the smaller
  answer.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  @impl Mix.Task
  def run(args) do
    case args do
      [] ->
        Mix.raise("""
        which seed?

            mix cms.seed priv/repo/qa_seeds.exs

        Available:
        #{available()}
        """)

      [path | rest] ->
        seed(path, rest)
    end
  end

  defp seed(path, rest) do
    unless File.exists?(path) do
      Mix.raise("""
      no seed at #{path}

      Available:
      #{available()}
      """)
    end

    # `app.config` and not `app.start`: runtime.exs runs, so the Repo is
    # configured exactly as the app would configure it, and nothing is
    # supervised.
    Mix.Task.run("app.config")

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    # Seeds read and write encrypted columns (`Project.deploy_key`), and Cloak
    # resolves its key through the Vault process rather than at compile time.
    {:ok, _} = CodeMySpec.Vault.start_link([])
    {:ok, _} = CodeMySpec.Repo.start_link(pool_size: 2, log: false)

    # Contexts broadcast on write — `UserPreferences.update_user_preferences/2`
    # is one of many — and without the registry that surfaces as
    #
    #     ** (ArgumentError) unknown registry: CodeMySpec.PubSub
    #
    # from inside a context call, which reads as a broken context rather than a
    # missing process. A seed that calls contexts rather than writing rows by
    # hand is the normal case and the better one, so the registry belongs here.
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: CodeMySpec.PubSub)

    Mix.shell().info("→ #{path} (database only, no endpoint)")

    # Arguments after the path reach the script as `System.argv/0`, which is
    # what a script would read if it had been run by `mix run`.
    System.argv(rest)
    Code.eval_file(path)
  end

  defp available do
    "priv/repo"
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map_join("\n", &"  #{&1}")
  end
end
