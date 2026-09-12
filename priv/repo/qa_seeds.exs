# QA Seeds — Server (Postgres)
#
# Creates the minimum fixture needed to QA the hosted endpoint (`:4000`):
# user + personal account + membership + project linked via local_path.
#
# Usage: mix cms.seed priv/repo/qa_seeds.exs
#
# Not `mix run`: that boots the endpoint and dies `:eaddrinuse` whenever the dev
# server already holds :4000 — which is whenever you would want to seed it. The
# task starts the database and nothing else.
#
# Idempotent — safe to re-run. Prints credentials at the end so the QA agent
# can reuse them without spelunking the source.

import Ecto.Query

alias CodeMySpec.Repo
alias CodeMySpec.Accounts
alias CodeMySpec.Accounts.Member
alias CodeMySpec.Projects.Project
alias CodeMySpec.Stories
alias CodeMySpec.Stories.Story
alias CodeMySpec.Users
alias CodeMySpec.Users.User
alias CodeMySpec.Users.Scope

email = "qa@codemyspec.local"
# The QA user's own account, and the dev user is added to it as a member so the
# fixture project still shows up in the local project list.
#
# It used to live under the real `code-my-spec` account, for that visibility.
# That put it under an account owned by johns10@gmail.com, and
# `Accounts.get_account_owner/1` routes a question to its project's account
# owner — correctly. Composed, every `escalate_question` and `ask_user_question`
# from the sandbox landed in the real owner's real inbox, and QA could not
# verify a notification criterion without putting test traffic there. It
# reported `partial` and cleaned up after itself rather than leave two live
# entries (cd6f9eda). John's call, 2026-09-12: give it its own account.
#
# This also serves the worry the old comment had better than the old comment
# did. "We don't want the QA fixture user to administer the real account" is
# satisfied completely by an account that *is* the QA user's — it administers
# only its own — rather than by joining the real one at a lower rank.
target_account_slug = "qa-account"
target_account_name = "QA Account"
target_account_id = "22222222-2222-4222-8222-222222222222"
# Who still needs to see the fixture project in their own list.
visitor_email = "johns10@gmail.com"
project_id = "11111111-1111-4111-8111-111111111111"
project_name = "QA Fixture Project"
project_module = "QaFixtureProject"
# A sandbox beside the checkout, never the checkout itself.
#
# This used to default to `File.cwd!()`, which is the checkout you run `mix`
# from. The guard below only refuses when *another* project already claims the
# path, and the real project's `local_path` was NULL — so the fixture took the
# working checkout unopposed, and provisioning QA then pushed this entire
# codebase to a freshly created repository. It also meant the working directory
# resolved to the fixture rather than to the real project, silently, for weeks.
#
# `.code_my_spec/qa/plan.md` has always said the fixture lives in a sandbox
# with "only the minimal Phoenix shape"; the seed contradicted the plan.
default_sandbox = Path.expand("../code_my_spec_test_repos/qa_sandbox", File.cwd!())
local_path = System.get_env("QA_LOCAL_PATH") || default_sandbox

if local_path == File.cwd!() do
  IO.puts(:stderr, """

  Refusing to run: local_path #{inspect(local_path)} is the checkout you are
  running from. The QA fixture is a disposable sandbox — pointing it at a real
  working copy makes provisioning QA push that copy to a new repository, and
  makes every hook resolve the working directory to the fixture.

  Re-run without QA_LOCAL_PATH to use #{inspect(default_sandbox)}, or set it to
  a throwaway path.
  """)

  System.halt(1)
end

File.mkdir_p!(local_path)

IO.puts("\n=== QA Seeds — server ===")

# Refuse if `local_path` already belongs to a different project. Running this
# seed from a real project checkout (the default `mix run` working dir) used
# to stamp the fixture's local_path onto your real project's path, producing
# two rows that collided in WorkingDirScope.
case Repo.one(
       from p in Project,
         where: p.local_path == ^local_path and p.id != ^project_id,
         limit: 1
     ) do
  nil ->
    :ok

  %Project{name: existing_name, id: existing_id} ->
    IO.puts(:stderr, """

    Refusing to run: local_path #{inspect(local_path)} is already linked to
    project "#{existing_name}" (#{existing_id}).

    The QA fixture would collide with that real project and cause
    Ecto.MultipleResultsError in CodeMySpecLocalWeb.Plugs.WorkingDirScope.

    Re-run with a throwaway path:
        QA_LOCAL_PATH=/tmp/cms_qa mix run priv/repo/qa_seeds.exs
    """)

    System.halt(1)
end

# 1. User
user =
  case Users.get_user_by_email(email) do
    nil ->
      {:ok, user} = Users.register_user(%{email: email})

      # No password. There is no password form — `/users/log-in` offers GitHub,
      # Google, and a magic link, and the page says so ("Passwordless from day
      # one"). Setting one gave the seed's own output a credential that could
      # not be used, and every per-story brief copied it out of the QA plan.
      #
      # Confirmed, or this user cannot log in at all: an unconfirmed account's
      # magic link is refused on purpose, to prevent session fixation.
      {:ok, user} = user |> User.confirm_changeset() |> Repo.update()

      IO.puts("  user: created #{email} (confirmed)")
      user

    user ->
      # An existing fixture user predating the line above is in the dead-end
      # state, and re-running the seed is how someone would try to fix it.
      user =
        if is_nil(user.confirmed_at) do
          {:ok, user} = user |> User.confirm_changeset() |> Repo.update()
          IO.puts("  user: exists #{email} (confirmed now — it was not)")
          user
        else
          IO.puts("  user: exists #{email}")
          user
        end

      user
  end

scope = Scope.for_user(user)

# 1a. CLI OAuth application — required by the `/codemyspec:authenticate` flow
#     and any criterion that exercises the dashboard install funnel. Inserted
#     idempotently keyed on `uid = "codemyspec-cli"`. Previously only seeded
#     in the test env via `CodeMySpec.OauthFixtures.cli_oauth_application_fixture/1`;
#     dev-DB QA runs had to insert it via psql by hand (issue 3dbf422e).
#
#     NOTE: secret is intentionally empty — the CLI is a TRUSTED PUBLIC client
#     that uses PKCE, not a confidential client. `OAuthController` recognises
#     this uid and grants silent approval without exchanging a secret. The
#     `claude-mcp-connector` in `priv/repo/seeds.exs` IS a confidential client
#     and uses a generated secret; that's a different OAuth flow.
cli_oauth_uid = "codemyspec-cli"
now = DateTime.utc_now() |> DateTime.truncate(:second)

case Repo.one(from a in "oauth_applications", where: a.uid == ^cli_oauth_uid, select: a.id) do
  nil ->
    {1, _} =
      Repo.insert_all(
        "oauth_applications",
        [
          %{
            name: "CodeMySpec CLI",
            uid: cli_oauth_uid,
            secret: "",
            redirect_uri: "http://localhost:9876/oauth/callback",
            scopes: "",
            inserted_at: now,
            updated_at: now
          }
        ]
      )

    IO.puts("  oauth_application: created codemyspec-cli")

  _id ->
    IO.puts("  oauth_application: exists codemyspec-cli")
end

# 2. The QA account, made here rather than borrowed. See the note at the top:
#    an account it owns is what keeps sandbox escalations out of a real inbox.
account =
  case Repo.one(from a in Accounts.Account, where: a.slug == ^target_account_slug) do
    nil ->
      account =
        Repo.insert!(%Accounts.Account{
          id: target_account_id,
          name: target_account_name,
          slug: target_account_slug
        })

      IO.puts("  account: created #{target_account_slug} (#{account.id})")
      account

    account ->
      IO.puts("  account: using existing #{target_account_slug} (#{account.id})")
      account
  end

# 3. Membership. The QA user OWNS this one — that is the whole point, since
#    `Accounts.get_account_owner/1` is what decides whose inbox a question
#    reaches.
#
#    `get_account_owner/1` takes the OLDEST owner when there are several, so a
#    second owner added later would not displace this one — but one owner is
#    the state to keep, and the dev user below is deliberately a member.
upsert_member = fn user_id, role, label ->
  case Repo.one(from m in Member, where: m.user_id == ^user_id and m.account_id == ^account.id) do
    nil ->
      %Member{}
      |> Member.changeset(%{user_id: user_id, account_id: account.id, role: role})
      |> Repo.insert!()

      IO.puts("  member: added #{label} as #{role} of #{target_account_slug}")

    %Member{role: ^role} ->
      IO.puts("  member: #{label} already #{role}")

    existing ->
      existing
      |> Member.changeset(%{role: role})
      |> Repo.update!()

      IO.puts("  member: corrected #{label} from #{existing.role} to #{role}")
  end
end

upsert_member.(user.id, :owner, email)

# The dev user as a member, so the fixture project still appears in their
# project list — the visibility the old arrangement was reaching for, without
# making them the owner the router picks.
case Repo.one(from u in CodeMySpec.Users.User, where: u.email == ^visitor_email) do
  nil -> IO.puts("  member: no #{visitor_email} on this box, skipping the visitor")
  visitor -> upsert_member.(visitor.id, :member, visitor_email)
end

# 4. Project linked to this checkout via local_path. Bootstrap changeset
#    accepts id + account_id directly (no scope dependency).
project =
  case Repo.get(Project, project_id) do
    nil ->
      {:ok, project} =
        %Project{}
        |> Project.bootstrap_changeset(%{
          id: project_id,
          name: project_name,
          module_name: project_module,
          account_id: account.id,
          local_path: local_path,
          status: :created
        })
        |> Repo.insert()

      IO.puts("  project: created #{project_name} (local_path=#{local_path})")
      project

    project ->
      changes =
        []
        |> Kernel.then(fn acc ->
          if project.local_path != local_path, do: [{:local_path, local_path} | acc], else: acc
        end)
        |> Kernel.then(fn acc ->
          if project.account_id != account.id, do: [{:account_id, account.id} | acc], else: acc
        end)

      if changes == [] do
        IO.puts("  project: exists (#{project_name})")
        project
      else
        {:ok, project} =
          project
          |> Ecto.Changeset.change(Map.new(changes))
          |> Repo.update()

        IO.puts("  project: updated #{inspect(Keyword.keys(changes))}")
        project
      end
  end

# 4b. A deploy key on the QA project.
#
#     Devices authenticate as *machines*, not as people: a sprite has no
#     signed-in user and holds only its project's deploy key. So QA cannot
#     exercise device onboarding through the browser session at all — it needs
#     this credential, and without it in the seed every session has to mint one
#     before it can start.
#
#     Through `update_project/3` rather than `Ecto.Changeset.change/2`, because
#     `put_deploy_key_hash/1` is what makes the key findable: the API looks a
#     project up by hash, so a key written around the changeset authenticates
#     nothing. That exact mistake is already recorded in the spex fixtures.
qa_deploy_key = "dk_qa_codemyspec_local"

project =
  case CodeMySpec.Projects.update_project(
         %CodeMySpec.Users.Scope{
           user: user,
           user_id: user.id,
           active_account: account,
           active_account_id: account.id,
           active_project: project,
           active_project_id: project.id
         },
         project,
         %{deploy_key: qa_deploy_key}
       ) do
    {:ok, updated} ->
      IO.puts("  deploy key: #{qa_deploy_key}  (authenticate as a machine with this)")
      updated

    {:error, reason} ->
      IO.puts(
        "  deploy key: NOT set (#{inspect(reason)}) — device QA will not be able to announce"
      )

      project
  end

# 4b. No main working copy.
#
# `designate_main/2` is the only writer and there is no undesignate control, so
# testing "a project with no main checkout" consumes the premise: the first run
# designates one and every run after it silently tests something else. Observed
# on the 963 pass — the fixture went from three copies and none designated to
# `d1540d93` designated, with no surface that could put it back (d05cd22e).
#
# One-way is right as product behaviour. Once somebody has a main checkout they
# want one, and an "unset it" control invites a project with checkouts and no
# agent for no reason. So the way back to the premise belongs here, in the seed
# that owns the fixture's starting state, rather than in a product change.
#
# Written directly rather than through the context for the same reason: there
# is no function for this, deliberately.
main_copies_cleared =
  case Ecto.Adapters.SQL.query(
         Repo,
         "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'working_copies' LIMIT 1"
       ) do
    {:ok, %{num_rows: n}} when n > 0 ->
      {count, _} =
        from(w in "working_copies",
          where: w.project_id == type(^project.id, :binary_id) and w.main == true
        )
        |> Repo.update_all(set: [main: false])

      count

    _ ->
      nil
  end

case main_copies_cleared do
  nil -> IO.puts("  main copy: skipped (working_copies table not found)")
  0 -> IO.puts("  main copy: none designated — the 2906 premise already holds")
  n -> IO.puts("  main copy: cleared #{n} designation(s), back to the 2906 premise")
end

# 5. QA stories. Dedicated stories under the QA project — anything QA mutates
#    (rules, scenarios, questions, criteria) lands on these instead of dev
#    project stories. Add new entries to qa_stories below as new feature areas
#    need their own isolated test target.
#
# Guard against environments where the stories table does not yet exist
# (e.g. a fresh checkout with partial migrations, or a DB that predates
# the stories schema). If the table is absent we skip story seeding and
# emit a note — the user/account/project seeds above still land cleanly.
stories_table_exists? =
  case Ecto.Adapters.SQL.query(
         Repo,
         "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'stories' LIMIT 1"
       ) do
    {:ok, %{num_rows: n}} -> n > 0
    _ -> false
  end

stories_module_loaded? = Code.ensure_loaded?(CodeMySpec.Stories)

{_story_ids, stories_block} =
  if stories_table_exists? and stories_module_loaded? do
    qa_scope = %{
      scope
      | active_account: account,
        active_account_id: account.id,
        active_project: project,
        active_project_id: project.id
    }

    qa_stories = [
      %{
        title: "QA: Three Amigos UI smoke",
        description:
          "Dedicated story for exercising the Three Amigos LiveView wall (story 559's UI surface). All persona/rule/scenario/question mutations from QA land here, not on the real story 559.",
        priority: 100
      }
    ]

    ids =
      Enum.map(qa_stories, fn attrs ->
        case Repo.one(
               from s in Story,
                 where: s.title == ^attrs.title and s.project_id == ^project.id
             ) do
          nil ->
            {:ok, story} = Stories.create_story(qa_scope, attrs)
            IO.puts("  story: created \"#{story.title}\" (id=#{story.id})")
            {attrs.title, story.id}

          existing ->
            IO.puts("  story: exists \"#{existing.title}\" (id=#{existing.id})")
            {existing.title, existing.id}
        end
      end)

    block =
      ids
      |> Enum.map_join("\n", fn {title, id} ->
        "  - #{title} (id=#{id})\n      http://127.0.0.1:4003/projects/qa-fixture-project/stories/#{id}/three-amigos"
      end)

    {ids, block}
  else
    IO.puts("  stories: skipped (table not found or module not loaded)")
    {[], "  (stories table unavailable — run pending migrations)"}
  end

IO.puts("""

=== QA Fixture (server) ===
Hosted UI:    http://127.0.0.1:4000
Email:        #{email}
Account slug: #{target_account_slug}
Account id:   #{account.id}
Project id:   #{project.id}
Local path:   #{local_path}

QA stories:
#{stories_block}

Log in — passwordless, so this is the whole procedure:
  1. /users/log-in, enter the email above, "Email me a login link"
  2. /dev/mailbox — the local adapter catches it
  3. the link is minted with the configured host
     (https://dev.codemyspec.com/users/log-in/<token>); rewrite the origin to
     http://127.0.0.1:4000 before following it, or you leave the local app
  4. it lands on /app. Single-use — a re-run needs a fresh link.

For local web (port 4003), the same project resolves via X-Working-Dir or
Plugs.WorkingDirScope as long as `local_path` matches PWD on each request.
""")
