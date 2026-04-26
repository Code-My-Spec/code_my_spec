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
local_path = File.cwd!()

IO.puts("\n=== QA Seeds — server ===")

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

story_ids =
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

stories_block =
  story_ids
  |> Enum.map_join("\n", fn {title, id} ->
    "  - #{title} (id=#{id})\n      http://127.0.0.1:4003/projects/qa-fixture-project/stories/#{id}/three-amigos"
  end)

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
