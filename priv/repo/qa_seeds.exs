# QA Seeds — Server (Postgres)
#
# Creates the minimum fixture needed to QA the hosted endpoint (`:4000`):
# user + personal account + membership + project linked via local_path.
#
# Usage: mix run priv/repo/qa_seeds.exs
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
alias CodeMySpec.Users.Scope

email = "qa@codemyspec.local"
password = "qa-password-123!"
# Project lives under the existing Code My Spec team account so it shows up
# in the local project list when authenticated as the dev user.
target_account_slug = "code-my-spec"
project_id = "11111111-1111-4111-8111-111111111111"
project_name = "QA Fixture Project"
project_module = "QaFixtureProject"
local_path = System.get_env("QA_LOCAL_PATH") || File.cwd!()

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
      {:ok, {user, _expired_tokens}} = Users.update_user_password(user, %{password: password})
      IO.puts("  user: created #{email}")
      user

    user ->
      IO.puts("  user: exists #{email}")
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

# 2. Resolve target account. We use the existing Code My Spec team account so
#    the QA Fixture Project shows up in the dev user's local project list.
account =
  case Repo.one(from a in Accounts.Account, where: a.slug == ^target_account_slug) do
    nil ->
      raise "Account `#{target_account_slug}` not found — create it first or pick another slug"

    account ->
      IO.puts("  account: using existing #{target_account_slug} (#{account.id})")
      account
  end

# 3. Member — qa user joins the Code My Spec team account as :member (not
#    owner; we don't want the QA fixture user to administer the real account).
case Repo.one(
       from m in Member, where: m.user_id == ^user.id and m.account_id == ^account.id
     ) do
  nil ->
    %Member{}
    |> Member.changeset(%{user_id: user.id, account_id: account.id, role: :member})
    |> Repo.insert!()

    IO.puts("  member: added #{email} as member of #{target_account_slug}")

  _existing ->
    IO.puts("  member: exists")
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
  case Ecto.Adapters.SQL.query(Repo, "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'stories' LIMIT 1") do
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
Password:     #{password}
Account slug: #{target_account_slug}
Account id:   #{account.id}
Project id:   #{project.id}
Local path:   #{local_path}

QA stories:
#{stories_block}

Login at /users/log-in (password form), then visit /app.
For local web (port 4003), the same project resolves via X-Working-Dir or
Plugs.WorkingDirScope as long as `local_path` matches PWD on each request.
""")
