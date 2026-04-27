ExUnit.start(exclude: [:scenario, :e2e, :pending, :record_google_login_shape])
Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, :manual)

case System.get_env("LOG_LEVEL") do
  nil -> :warning
  level -> Logger.configure(level: String.to_existing_atom(level))
end

# Define mock for environments in tests
Mox.defmock(CodeMySpec.MockEnvironment, for: CodeMySpec.Environments.EnvironmentsBehaviour)

# Define mock for Git operations in tests
Mox.defmock(CodeMySpec.MockGit, for: CodeMySpec.Git.Behaviour)

# Initialize test fixture repositories
CodeMySpec.Support.TestAdapter.ensure_fixture_fresh()

# Start the test repo pool for fast directory reuse
{:ok, _} = CodeMySpec.Support.TestAdapter.Pool.start_link()

# Use TestAdapter as default Git implementation for tests
Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.Support.TestAdapter)

# Use RecordingEnvironment as default for local environment in tests
Application.put_env(:code_my_spec, :environment, CodeMySpec.Support.RecordingEnvironment)

# Use MockTmuxAdapter as default for tmux operations in tests
Application.put_env(:code_my_spec, :tmux_adapter, CodeMySpec.Environments.MockTmuxAdapter)
