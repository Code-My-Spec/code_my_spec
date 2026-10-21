# Run after creating and connecting a project through the disposable desktop.
# MIX_ENV=desktop DATABASE_URL=... mix cms.seed \
#   priv/repo/qa_1112_assisted_setup_seed.exs QA_DATABASE PROJECT_ID

alias CodeMySpec.{Agents, Repo, WorkingCopies}
alias CodeMySpec.Agents.ModelSetting
alias CodeMySpec.UserPreferences.DesktopUser

[expected_database, project_id] =
  case System.argv() do
    [database, project] -> [database, project]
    _ -> Mix.raise("Pass the disposable QA database name and selected project UUID.")
  end

unless DesktopUser.active?(), do: Mix.raise("Run this seed with MIX_ENV=desktop.")

unless Regex.match?(~r/\Aqa_?1112_[a-zA-Z0-9_]+\z/, expected_database) do
  Mix.raise("The disposable database name must begin with qa1112_ or qa_1112_.")
end

# The database name on Postgres, the file's name on SQLite (the desktop).
actual_database = Repo.config()[:database] |> Path.basename() |> Path.rootname()

unless actual_database == expected_database do
  Mix.raise("Connected database does not match the explicitly supplied QA database.")
end

scope = DesktopUser.scope()

unless scope && scope.active_project_id == project_id && scope.active_project do
  Mix.raise("Select the requested project through this desktop's setup first.")
end

copy = WorkingCopies.main(scope)
unless copy, do: Mix.raise("Connect the project's main working copy through desktop setup first.")

case Repo.get_by(ModelSetting, user_id: scope.user.id, role: :main) do
  nil ->
    :ok

  %{provider: "claude-code", model: nil} ->
    :ok

  _ ->
    Mix.raise(
      "This desktop user already has a different main-agent model setting; leave it intact and use a fresh QA database."
    )
end

{:ok, _setting} = Agents.put_model_setting(scope, :main, "claude-code", nil)
{:ok, {"claude-code", nil}, :set} = Agents.resolve_model(scope, :main)

IO.puts("""
Configured the disposable desktop user's main agent for the local Claude CLI.
Database: #{actual_database}
Project: #{project_id}
Main working copy: #{copy.id}

In the running desktop, open /app/projects/#{project_id}/agent-conversation.
The desktop harness must have an authenticated Claude CLI available on its PATH.
This seed neither authenticates that CLI nor starts an agent or copies credentials.
Wait for the real main agent to become available, then return to /app and ask
for setup help. Record the delivered setup results and an actual agent reply.
A model setting alone is not proof of provider connectivity or successful help.

Use a fresh disposable database for another clean run. No shared preferences,
project files, prerequisite results, or provider credentials were changed.
""")
