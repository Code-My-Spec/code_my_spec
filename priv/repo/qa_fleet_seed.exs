# A QA fleet: one project, four checkouts, one agent role on each.
#
# Usage: mix cms.seed priv/repo/qa_fleet_seed.exs
#
# ## Why four checkouts rather than four agents on one
#
# `refuse_if_occupied/2` (`agents.ex:602`) refuses to start an agent on a copy
# while the project has a main agent, and a checkout holds one agent anyway. So
# the shape story 1004 needs — two *coding* agents, to show that only the
# assigned one is woken (3184), plus a product agent to show the deciding is
# per-role (3179), plus a main agent (3185, 3186) — is one role per copy.
#
# Measured: staffing the single-copy fixture returned
# `{:main_copy_occupied, ".../math_test_project"}` for coding and qa, because
# the fixture's own seeded main agent was occupying it.
#
# ## Why the agents are started rather than written
#
# The previous fixture wrote rows with `status: :running` and no processes
# behind them. `record_running_on_copy/3` (`0c912986`) now reaps exactly that
# within ~60s of each harness report, and `project_wakeable?/2` then correctly
# ignores them — so every wake test failed for the fixture's reason while
# looking like the story's (`06eda4cf`, dismissed; `726766b0`).
#
# Rows are therefore not enough any more. This seed prepares the checkouts and
# the copies; the agents are staffed through the running app afterwards, which
# is the only place that can reach a harness:
#
#     curl -X POST localhost:4000/dev/copies/<copy_id>/staff \
#       -H 'Content-Type: application/json' -d '{"roles":["coding"]}'
#
# ## They cost tokens. Take them down.
#
# Real agents on `continuous: true` pick up work and spend model tokens, which
# is the whole reason the old fixture was rows. When the pass is finished:
#
#     curl -X POST localhost:4000/dev/copies/<copy_id>/continuous \
#       -H 'Content-Type: application/json' -d '{"continuous": false}'
#     curl -X POST localhost:4000/dev/agents/<agent_id>/stop
#
# Idempotent. Re-run it.

import Ecto.Query

alias CodeMySpec.Accounts
alias CodeMySpec.Projects
alias CodeMySpec.Projects.Project
alias CodeMySpec.Repo
alias CodeMySpec.Users
alias CodeMySpec.Users.Scope

project_name = "QA Agent Fleet"
email = "qa@codemyspec.local"
root = "/Users/johndavenport/Documents/github/code_my_spec_test_repos/qa_fleet"
template = "/Users/johndavenport/Documents/github/math_test_project"

# One role per checkout, named so the path says what lives there.
copies = [
  {"coding-a", :coding},
  {"coding-b", :coding},
  {"product", :product},
  {"main", :main}
]

# ------------------------------------------------------------------- account
user =
  case Repo.one(from u in Users.User, where: u.email == ^email) do
    nil ->
      IO.puts(:stderr, """

      No user #{email}. This seed reuses the QA fixture's account rather than
      minting one — account creation is its own pipeline and a second fixture
      account is one more thing to clean up.

      Run `mix cms.seed priv/repo/qa_wake_seed.exs` first.
      """)

      System.halt(1)

    u ->
      u
  end

scope = Scope.for_user(user)

account =
  case Accounts.list_accounts(scope) do
    [a | _] ->
      a

    [] ->
      IO.puts(:stderr, "No account for #{email}. Run qa_seeds.exs first.")
      System.halt(1)
  end

IO.puts("  account: #{account.id} (#{email})")

scope = %{scope | active_account: account, active_account_id: account.id}

# ------------------------------------------------------------------- project
project =
  case Repo.one(from p in Project, where: p.name == ^project_name) do
    nil ->
      {:ok, p} =
        Projects.create_project(scope, %{
          name: project_name,
          module_name: "QaFleet",
          code_repo: "https://github.com/Code-My-Spec/math_test_project",
          local_path: Path.join(root, "coding-a")
        })

      p

    p ->
      p
  end

IO.puts("  project: #{project.id} (#{project_name})")

scope = %{scope | active_project: project, active_project_id: project.id}

# ----------------------------------------------------------------- checkouts
#
# Copied from the existing fixture rather than generated: the graph is computed
# from files, and `math_test_project` already has the shape the analyzers and
# the component sync expect. A directory holding nothing produces a graph with
# nothing actionable, and an agent with nothing to do is not woken — which
# looks exactly like the wake being broken.
File.mkdir_p!(root)

unless File.exists?(Path.join(template, "mix.exs")) do
  IO.puts(:stderr, "\nNo template app at #{template}. Run qa_wake_seed.exs first.\n")
  System.halt(1)
end

for {name, _role} <- copies do
  path = Path.join(root, name)

  if File.exists?(Path.join(path, "mix.exs")) do
    IO.puts("  checkout: exists #{path}")
  else
    File.mkdir_p!(path)
    {_, 0} = System.cmd("cp", ["-R", template <> "/.", path])
    # Each checkout is its own harness root; carrying the template's identity
    # would make two roots present the same harness id, which is the collapse
    # documented in the light-harness plan.
    File.rm_rf!(Path.join(path, ".cms_harness.json"))
    File.rm_rf!(Path.join(path, "_build"))
    File.rm_rf!(Path.join(path, "deps"))
    IO.puts("  checkout: created #{path}")
  end
end

IO.puts("""

Seeded the project and #{length(copies)} checkout(s).

Next, onboard a harness for each — a copy with no harness has no graph at its
vantage, so its agent's menu is empty and no wake is sent:

    mix cms.seed priv/repo/qa_wake_key.exs      # prints a deploy key

#{Enum.map_join(copies, "\n", fn {name, role} -> "    # #{role}\n    CMS_DEPLOY_KEY=<key> mix cms.harness.onboard #{Path.join(root, name)} --project #{project.id}" end)}

Then staff one role on each copy, through the running app:

    curl -X POST localhost:4000/dev/copies/<copy_id>/staff \\
      -H 'Content-Type: application/json' -d '{"roles":["<role>"]}'

Project: #{project.id}
Account: #{account.id}
Root:    #{root}
""")
