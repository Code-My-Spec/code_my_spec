defmodule CodeMySpec.AgentTasks.Setup.SpexConfig do
  @moduledoc """
  Setup step: `mix spex` runs in `:test` and against a database that exists.

  Two halves, and the second is the one that bites. `preferred_envs` puts the
  task in the right environment; the alias is what creates and migrates the
  database it lands in.

  `mix test` has carried `["ecto.create --quiet", "ecto.migrate --quiet",
  "test"]` since `phx.new` generated it, so the per-worktree partition named by
  `MIX_TEST_PARTITION` is provisioned on first use. `mix spex` had no such
  alias and loads no `test_helper`, so it was the one command an agent is told
  to run for BDD work that assumed its database already existed.

  Measured on the math project 2026-09-22: every analyzer spex run failed with
  `(Postgrex.Error) FATAL 3D000 database "math_test_project_testhbb1818bas"
  does not exist`, and later — once created by hand — with a table missing
  because a migration written that morning had never been applied there. The
  agent read both as its own specs failing. `bdd_specs_passing` cannot go green
  through a run that never started.

  CodeMySpec solved this for itself in `Mix.Tasks.Cms.CheckTestMigrations`,
  wired into its own `test_helper.exs`. That task lives in this repo and ships
  to nobody, so a generated project gets neither it nor the guard — the alias
  is what closes it there.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, "mix.exs", :spex_config, "`mix.exs` not synced") do
      nil -> :valid
      msg -> {:invalid, msg}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(_scope, _task) do
    {:ok,
     """
     # Configure Spex

     Add to `cli/0` in `mix.exs`:

     ```elixir
     def cli do
       [preferred_envs: [spex: :test]]
     end
     ```

     And add a `spex` alias to `aliases/0`, beside the `test` one:

     ```elixir
     spex: ["ecto.create --quiet", "ecto.migrate --quiet", "spex"],
     ```

     An alias may share a task's name and still invoke it — that is how the
     generated `test` alias works. Without this, `mix spex` runs against the
     partition `MIX_TEST_PARTITION` names and never creates or migrates it, so
     the first run on a fresh worktree fails `FATAL 3D000 ... does not exist`
     and every later one misses whatever migrations landed since. `mix spex`
     loads no `test_helper`, so there is nowhere else for the check to live.
     """}
  end
end
