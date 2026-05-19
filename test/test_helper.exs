ExUnit.start(exclude: [:scenario, :e2e, :pending, :record_google_login_shape, :record_github_login_shape])
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

# Own the embedding TestBackend ETS table from a long-lived agent so it
# survives across async tests. Without a stable owner the table dies with
# whichever test process happened to create it, breaking the next concurrent
# test that touches the embeddings pipeline.
{:ok, owner} =
  Agent.start_link(
    fn ->
      :ets.new(
        :code_my_spec_embeddings_test_backend,
        [:set, :public, :named_table, read_concurrency: true]
      )
    end,
    name: CodeMySpec.Embeddings.TestBackend.TableOwner
  )

# Don't let GC reap the owner — pin it for the full test run.
Process.put(:test_backend_owner, owner)
