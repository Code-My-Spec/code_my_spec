# QA Seeds — a project with agents that can actually be woken
#
# Usage: mix cms.seed priv/repo/qa_wake_seed.exs
#
# Not `mix run`: that boots the endpoint and dies `:eaddrinuse` whenever the dev
# server already holds :4000, which is whenever you would want to seed.
#
# ## What this is for
#
# Seven criteria on story 1062 are about an idle agent being woken when work
# appears — 3242, 3243, 3244, 3249, 3250, 3303, 3351. QA could not exercise any
# of them, for a reason no amount of testing skill gets past: every agent row on
# the real project has `continuous = false`, so `watch_active_projects/0`
# correctly finds nothing to watch, and there is no watcher to observe. The
# absence is correct behaviour, and it makes the behaviour unobservable.
#
# The two ways out that do not involve a seed are both bad. Toggling
# `continuous` on a live `status = running` agent fires real wake messages into
# a teammate's conversation. Standing up an agent on the real project risks a
# product agent autonomously triaging the real backlog as a side effect of a
# probe. A QA agent was right to refuse both.
#
# So: a project of its own, with its own checkout, its own agents, and enough
# real work on the graph that waking one means something.
#
# ## Why a generated app rather than an empty directory
#
# The graph is computed from files. A project whose `local_path` holds nothing
# produces a graph with nothing actionable in it, and an agent with nothing to
# do is not woken — which looks exactly like the wake being broken. `mix
# phx.new` gives the shape the analyzers and the component sync expect, which is
# what makes "work appeared" a real state rather than a fixture flag.
#
# Idempotent. Re-run it.

import Ecto.Query

alias CodeMySpec.Accounts
alias CodeMySpec.Projects
alias CodeMySpec.Projects.Project
alias CodeMySpec.Repo
alias CodeMySpec.Stories
alias CodeMySpec.Users
alias CodeMySpec.Users.Scope
alias CodeMySpec.Users.User

email = "qa@codemyspec.local"
project_name = "Math Test Project"
app_name = "math_test_project"

IO.puts("\n=== QA wake seed ===")

# Where the app lives, in order of trust.
#
# The project's own `local_path` first, because if this project already exists
# that is the answer and anything computed here is a guess that will fight it.
# Seeding from a worktree taught me that the hard way: `Path.expand("../…",
# File.cwd!())` resolves against whichever checkout you happen to run from, so
# running this from `.claude/worktrees/<name>` generated a Phoenix app *inside
# the worktrees directory* and stamped that path onto the project — quietly
# repointing a fixture that had been correct.
#
# Then the environment, for a throwaway run. Then a sibling of the repository
# root, which is `git rev-parse --show-toplevel` on the common dir rather than
# `File.cwd!()` — those differ in a worktree and only the first is stable.
existing_path =
  Repo.one(from p in Project, where: p.name == ^project_name, select: p.local_path)

repo_root =
  case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
         stderr_to_stdout: true
       ) do
    {out, 0} -> out |> String.trim() |> Path.dirname()
    _ -> File.cwd!()
  end

local_path =
  existing_path || System.get_env("QA_WAKE_LOCAL_PATH") ||
    Path.expand("../#{app_name}", repo_root)

if local_path == File.cwd!() or String.contains?(local_path, "/.claude/worktrees/") do
  IO.puts(:stderr, """
  Refusing: #{inspect(local_path)} is a checkout or sits inside .claude/worktrees.

  The fixture is a disposable app of its own, not something living among git
  worktrees where `just` and the harness will try to treat it as one.
  """)

  System.halt(1)
end

# ---------------------------------------------------------------- the app
#
# Generated, not mocked. `--no-install` because nothing here compiles it — the
# graph reads the tree, it does not build it — and fetching deps turns a seed
# into a coffee break.
if File.exists?(Path.join(local_path, "mix.exs")) do
  IO.puts("  app: exists at #{local_path}")
else
  IO.puts("  app: generating with phx.new at #{local_path} …")
  File.mkdir_p!(Path.dirname(local_path))

  case System.cmd(
         "mix",
         ["phx.new", local_path, "--app", app_name, "--no-install", "--no-mailer"],
         stderr_to_stdout: true,
         env: [{"MIX_ENV", "dev"}]
       ) do
    {_out, 0} ->
      IO.puts("  app: generated")

    {out, code} ->
      IO.puts(:stderr, "phx.new failed (#{code}):\n#{out}")
      System.halt(1)
  end
end

# The harness looks for this, and a project without it is not a working copy.
File.mkdir_p!(Path.join([local_path, ".code_my_spec", "spec"]))

# ---------------------------------------------------------------- user, account
user =
  case Users.get_user_by_email(email) do
    nil ->
      {:ok, u} = Users.register_user(%{email: email})
      {:ok, u} = u |> User.confirm_changeset() |> Repo.update()
      IO.puts("  user: created #{email}")
      u

    u ->
      IO.puts("  user: exists #{email}")
      u
  end

scope = Scope.for_user(user)

account =
  case Accounts.list_accounts(scope) do
    [a | _] ->
      IO.puts("  account: #{a.name}")
      a

    [] ->
      IO.puts(:stderr, "No account for #{email}. Run qa_seeds.exs first.")
      System.halt(1)
  end

scope = %{scope | active_account: account, active_account_id: account.id}

# ---------------------------------------------------------------- the project
project =
  case Repo.one(from p in Project, where: p.name == ^project_name) do
    nil ->
      {:ok, p} =
        Projects.create_project(scope, %{
          name: project_name,
          module_name: Macro.camelize(app_name),
          local_path: local_path
        })

      IO.puts("  project: created #{p.id}")
      p

    p ->
      {:ok, p} = Projects.update_project(scope, p, %{local_path: local_path})
      IO.puts("  project: exists #{p.id}")
      p
  end

scope = %{scope | active_project: project, active_project_id: project.id}

# ---------------------------------------------------------------- work to do
#
# Released for development, because `Preloader` filters on `ready_for_dev` and a
# parked story produces no requirement nodes — so a project of parked stories
# has nothing actionable and nobody to wake.
stories = [
  {"Adding two numbers gives their sum",
   "As someone doing arithmetic, I want to add two numbers, so that I get their sum."},
  {"Dividing by zero is refused rather than crashing",
   "As someone doing arithmetic, I want division by zero refused, so that a bad input does not take the calculation down."},
  {"A calculation I ran is still there when I come back",
   "As someone doing arithmetic, I want my last calculation kept, so that I can check what I asked for."}
]

for {title, description} <- stories do
  case Repo.one(
         from s in CodeMySpec.Stories.Story,
           where: s.project_id == ^project.id and s.title == ^title
       ) do
    nil ->
      {:ok, story} =
        Stories.create_story(scope, %{
          title: title,
          description: description,
          ready_for_dev: true
        })

      IO.puts("  story: created #{story.title}")

    story ->
      IO.puts("  story: exists #{story.title}")
  end
end

IO.puts("""

Seeded. What is NOT done here, on purpose:

  The working copy and its agents. A working copy is a claim that a machine is
  serving this tree, and minting one from a seed produces a checkout no harness
  is behind — which reads as a connected copy that never reports, the exact
  phantom that makes a harness look broken.

  Onboard it instead, which is the real path and takes one command:

      cd #{local_path}
      cms harness.onboard

  Then start the agents you want woken, on that copy:

      product and coding roles, engine alloy, provider claude-code,
      continuous: true

  `GraphWatcher.watch_active_projects/0` picks the project up from the first
  continuous agent, so the watcher exists from that moment and the wake criteria
  (3242, 3243, 3244, 3249, 3250, 3303, 3351) become observable.

Project: #{project.id}
Path:    #{local_path}
Login:   #{email} (magic link via /dev/mailbox)
""")
