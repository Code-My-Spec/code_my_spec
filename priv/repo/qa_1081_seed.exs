# QA Seed — Story 1081 (telemetry)
#
# The QA Fixture Project's `setup_options` was set before `:telemetry` existed
# as an option, so the console renders no telemetry step at all. Adds it
# without touching any other option.
#
# Usage: mix cms.seed priv/repo/qa_1081_seed.exs

alias CodeMySpec.Projects.Project
alias CodeMySpec.Provisioning
alias CodeMySpec.Provisioning.EnvironmentRepository
alias CodeMySpec.Repo
alias CodeMySpec.UserPreferences
alias CodeMySpec.Users

project_id = "11111111-1111-4111-8111-111111111111"
email = "qa@codemyspec.local"

user = Users.get_user_by_email(email) || raise "no user #{email} -- run qa_seeds.exs first"
project = Repo.get!(Project, project_id)
scope = %{UserPreferences.scope_for(user) | active_project: project, active_project_id: project.id}

current = Provisioning.setup_options(scope)

if :telemetry in current do
  IO.puts("telemetry already enabled: #{inspect(current)}")
else
  {:ok, _project} = Provisioning.put_setup_options(scope, [:telemetry | current])
  IO.puts("enabled telemetry. options now: #{inspect(Provisioning.setup_options(scope))}")
end

# Gives the uat environment a fake server so the telemetry step's own
# behavior (not the server step's) is what gets exercised -- same seam the
# spex suite drives via EnvironmentRepository.put/3, no SQL involved.
{:ok, _env} = EnvironmentRepository.put(scope, "uat", %{ip: "203.0.113.10"})
IO.puts("uat environment now has ip: #{inspect(EnvironmentRepository.get(scope, "uat").ip)}")
