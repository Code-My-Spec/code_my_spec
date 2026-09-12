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

# ---------------------------------------------------------------- on-disk config
#
# `cms.harness.onboard` reads these two from the tree it is pointed at, and says
# so clearly when they are missing — but only one at a time, so a fixture
# without them costs two failed runs to discover.
#
# `config.yml` is which project this checkout is. Without it onboarding stops at
# "does not say which project it is".
config_yml = Path.join([local_path, ".code_my_spec", "config.yml"])

unless File.exists?(config_yml) do
  File.write!(config_yml, """
  account_id: #{account.id}
  description: "A generated Phoenix app used as a QA fixture for the requirement graph's watcher and wake criteria. Nothing here ships."
  module_name: #{Macro.camelize(app_name)}
  name: #{project_name}
  project_id: #{project.id}
  """)

  IO.puts("  config.yml: written")
end

# A deploy key is the credential onboarding mints the harness id against, and a
# project created through `create_project/2` has none — `ensure_deploy_key/2` is
# a separate call nothing here had made.
{:ok, project} = Projects.ensure_deploy_key(scope, project)
IO.puts("  deploy key: #{String.slice(project.deploy_key, 0, 12)}… (ensured)")

scope = %{scope | active_project: project}

# ---------------------------------------------------------------- the checkout
#
# Minted here rather than onboarded, which reverses what this seed said an hour
# ago. The reasoning then: a working copy no harness stands behind is a checkout
# that reads as connected and never reports, and onboarding is the real path.
#
# The reasoning was right about production and wrong about this. `cms
# harness.onboard` boots a full `CodeMySpecLocalWeb.Endpoint`, and on a shared
# box where :4003 and :4004 are already held it dies `eaddrinuse` — QA proved
# that and stopped rather than killing infrastructure eleven other projects use
# (issue 1c5540ae). So "onboard it properly" is not available here at all.
#
# What this fixture does and does not reach, measured rather than assumed.
#
# `AgentsRepository.continuous_project_scopes/0` starts a watcher from an
# **agent row**, not from a connected harness — so seeding agents here is enough
# to make a watcher exist, and the recompute criteria become observable through
# the requirements graph page:
#
#   3244  many writes at once cost one update
#   3351  a steady stream still gets a pass
#   3303  a recompute that succeeds passes without noise
#
# The wake criteria are a different matter, and an earlier version of this
# comment claimed otherwise. They are not reachable here:
#
#   3242  work becomes available while nobody is looking
#   3243  an idle agent does not sit through available work
#   3249  an agent's own process decides whether the change was for it
#   3250  a change for somebody else costs a query and nothing more
#
# All four are observed through an agent's conversation, and
# `Agents.dispatch_message/3` is a `with` chain that calls
# `Transport.impl().dispatch_message/5` **before** `open_conversation/2` and
# `record_sent/4`. In dev `Transport.impl/0` is `Transport.Harness`, so with no
# harness holding the copy the transport fails, the chain short-circuits, and
# nothing is ever written to the conversation. There is nothing to observe —
# not a missing wake, an undeliverable one.
#
# The spex pass because `config/test.exs` sets
# `:agent_transport` to `CodeMySpecTest.InProcessAgentTransport`. That is the
# only reason they can see a wake at all, and it is worth knowing before reading
# a green spex as evidence that the delivery path works.
#
# So those four need a harness actually holding this copy, and `cms
# harness.onboard` cannot run on this box: it boots a full
# `CodeMySpecLocalWeb.Endpoint` into ports :4003 and :4004 that are already held
# (issue 1c5540ae). They stay spex-covered until that is fixed.
#
# The copy is minted anyway, because the watcher half is real and worth having,
# and because a fixture that gets three of seven is better than none. `root`
# comes back nil on purpose — `issue/3` does not persist it, the harness sets it
# when it reports in, and nothing is reporting.
device_attrs = %{hostname: "qa-wake-fixture", kind: :local}

{:ok, device} = CodeMySpec.Devices.announce(scope, nil, device_attrs)

# Re-used rather than re-issued. `issue/3` recognises an existing copy by
# {device, root}, and `root` is nil on a seeded one because nothing reports it —
# so every run looked like a new checkout and minted another. Three runs, three
# copies, each with its own cache row and its own graph.
copy =
  case Repo.one(
         from w in CodeMySpec.WorkingCopies.WorkingCopy,
           where: w.project_id == type(^project.id, :binary_id) and not is_nil(w.root),
           order_by: [asc: w.inserted_at],
           limit: 1
       ) do
    nil ->
      IO.puts(:stderr, """

      No onboarded checkout for #{project_name}.

      This seed does not mint one any more. A copy it invents has no root and no
      harness behind it, and `Agents.dispatch_message/3` calls the transport
      before it records anything — so a wake to an agent on such a copy is
      undeliverable and never reaches the conversation. The four wake criteria
      then look broken when nothing is.

      Onboard it, which now works:

          mix cms.seed priv/repo/qa_wake_key.exs        # prints the deploy key
          CMS_DEPLOY_KEY=<that key> \\
            mix cms.harness.onboard #{local_path} \\
              --project #{project.id}

      Then re-run this seed and it will attach the agents to that checkout.
      """)

      System.halt(1)

    c ->
      IO.puts("  working copy: #{c.id} (onboarded, root #{c.root})")
      c
  end

scope = %{scope | active_working_copy_id: copy.id}

# ---------------------------------------------------------------- the agents
#
# `continuous: true` is the whole point — it is what
# `watch_active_projects/0` looks for, and its absence on every agent of every
# real project is why these criteria had nothing to observe.
#
# Two roles, because 3249 and 3250 are a pair: one agent's kind of work appears
# and the other's does not, and a single agent cannot show that the deciding is
# per-listener.
for {role, tools} <- [{"product", ["create_issue"]}, {"coding", ["create_issue"]}] do
  existing =
    Repo.one(
      from a in CodeMySpec.Agents.Agent,
        where:
          a.project_id == type(^project.id, :binary_id) and a.role == ^role and
            a.continuous == true
    )

  case existing do
    nil ->
      {:ok, agent} =
        CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "claude-code",
          role: role,
          working_copy: local_path,
          working_copy_id: copy.id,
          project_id: project.id,
          account_id: account.id,
          tools: tools,
          continuous: true,
          status: :running
        })

      IO.puts("  agent: created #{role} (#{agent.id})")

    agent ->
      IO.puts("  agent: exists #{role} (#{agent.id})")
  end
end

IO.puts("""

Seeded.

  A watcher will exist for this project: `watch_active_projects/0` runs at boot
  and picks up any project with a continuous agent. To get one without waiting
  for a restart, read this project's requirements graph once — `ensure_watching/1`
  starts one on demand. `/dev/state?project_id=#{project.id}` shows whether it
  is running.

  Reachable here (through the requirements graph page): 3244, 3351, 3303.

  NOT reachable here: 3242, 3243, 3249, 3250. They watch an agent's
  conversation, and `dispatch_message/3` calls the transport before it records
  anything — so with no harness holding this copy the message is undeliverable
  and never reaches the conversation. Blocked on 1c5540ae, not on this seed.

  The agents are rows, not processes. Nothing is running or spending tokens.

Project:      #{project.id}
Working copy: #{copy.id}
Path:         #{local_path}
Login:        #{email} (magic link via /dev/mailbox)
""")
