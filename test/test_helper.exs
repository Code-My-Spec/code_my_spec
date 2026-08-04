# :live hits real provider APIs and creates real resources. Never in the
# normal suite — run it deliberately with `mix test --only live`.
ExUnit.start(
  # :docker builds a real image on this machine — seconds, and it needs a
  # working daemon. Run it with `mix test --include docker` when the build
  # sequence changes.
  exclude: [
    :scenario,
    :e2e,
    :pending,
    :live,
    :docker,
    :registry,
    :record_google_login_shape,
    :record_github_login_shape
  ]
)

Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, :manual)

# The light harness tree. Its tests drive real processes — a watcher on a real
# directory, a Slipstream client against a real websocket — rather than
# constructing them, so they need the tree `cms harness` boots.
#
# Started here rather than from `CodeMySpecWeb.Application`'s test children, so
# the cloud application does not gain a compile-time reference to `CmsHarness`
# that only the test suite ever wanted. Its endpoint is `server: false` in test,
# so this costs a registry and an idle DynamicSupervisor.
{:ok, _} = CmsHarness.Supervisor.start_link([])

# Auto-load envs/test.env (gitignored) for e2e tests so OAuth client_id /
# secret / test-account creds are available without manual sourcing.
# Existing process env wins (you can override per-run).
if File.exists?("envs/test.env") do
  Dotenvy.source(["envs/test.env"], side_effect: false)
  |> case do
    {:ok, vars} ->
      Enum.each(vars, fn {k, v} ->
        if System.get_env(k) in [nil, ""], do: System.put_env(k, v)
      end)

    _ ->
      :ok
  end
end

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
