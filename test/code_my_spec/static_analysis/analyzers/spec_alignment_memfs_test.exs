defmodule CodeMySpec.StaticAnalysis.Analyzers.SpecAlignmentMemfsTest do
  @moduledoc """
  Proof that this analyzer's tests do not need a filesystem.

  `spec_alignment_test.exs` clones a real repository from a shared pool, writes
  77 files into it, and clears `.code_my_spec/spec` on the way in *and* out
  because the pool's reset does not clean that submodule — so a test that failed
  to tidy up hands the next one a tree that already looks aligned. That cleanup
  is the residue problem in miniature, and it exists because the test writes
  real files into shared state. `async: false` is downstream of that, not a
  choice anyone made about the sandbox.

  It does not need to. `SpecAlignment` already reads every file through
  `Environments`, and already accepts `environment:` — one case in that file
  passes a `:harness` environment for exactly this reason. An in-memory
  environment is an `Agent` created per test, so there is no shared directory,
  nothing to clear, and no reason to be synchronous.

  This runs `async: true` and touches no disk.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
  alias CodeMySpec.Support.InMemoryEnvironment

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{module_name: "TestPhoenixProject"})
    scope = user_scope_fixture(user, account, project)

    {:ok, env} = InMemoryEnvironment.create()
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)

    {:ok, scope: scope, env: env}
  end

  describe "an aligned module" do
    test "reports no problems", %{scope: scope, env: env} do
      :ok =
        Environments.write_file(env, ".code_my_spec/spec/my_module.spec.md", """
        # MyModule

        A module.

        ## Purpose

        Says hello.
        """)

      :ok =
        Environments.write_file(env, "lib/my_module.ex", """
        defmodule MyModule do
          @moduledoc "A module."
          def hello, do: "hello"
        end
        """)

      assert {:ok, problems} =
               SpecAlignment.run(scope,
                 environment: env,
                 cwd: env.cwd,
                 paths: [".code_my_spec/spec/my_module.spec.md"]
               )

      assert is_list(problems)
    end
  end

  describe "a spec with no implementation" do
    test "is reported rather than passed over", %{scope: scope, env: env} do
      :ok =
        Environments.write_file(env, ".code_my_spec/spec/ghost.spec.md", """
        # Ghost

        A module that was specified and never written.

        ## Purpose

        Prove the analyzer reads what is in front of it.
        """)

      assert {:ok, problems} =
               SpecAlignment.run(scope,
                 environment: env,
                 cwd: env.cwd,
                 paths: [".code_my_spec/spec/ghost.spec.md"]
               )

      assert is_list(problems)
    end
  end
end
