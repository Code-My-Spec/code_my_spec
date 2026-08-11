defmodule CodeMySpec.Integration.EmptyManifestNeverDeletesTest do
  @moduledoc """
  A scan that saw nothing must never be read as a working copy containing
  nothing.

  `Scanner.observe/2` used to answer `[]` in two unrelated situations: the tree
  is empty, and the environment cannot walk a tree at all. `FileSync.sync/2`
  could not tell those apart, so it handed the empty list to `reconcile/2` as a
  snapshot and `Files.delete_removed/2` removed every row whose path was not in
  it — which was all of them.

  That ran on the server, where `scope.environment` is a `Harness` with nothing
  local to walk, on the `get_next_requirement` path:

      17:22:25  sent 3936 observations for …/phx-new-generator
                server accepted the manifest: 3936 queued to reconcile
      17:24:28  [FileSync] 0 files scanned in 0ms, 0 upserted, 3936 removed

  and again an hour earlier, taking 452 Problems with it. The requirement graph
  then computed against an empty file set and returned `implementation_file` for
  `CodeMySpec.Authorization` — a 33-line module committed months ago with eleven
  call sites. Asking what to work on next destroyed the projection it had just
  answered from, and the answer was to rewrite working code.

  The fix is only at the point where the two are actually distinguishable —
  `Environments.stream_files/3` either refuses or it doesn't. A blanket "never
  delete on an empty manifest" rule was tried first and was wrong: it broke
  `FileSyncTest` "removes files that no longer exist on disk", where a project's
  only tracked file is deleted and the empty scan is the truth. Emptiness is not
  the signal. The refusal is.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Projects
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "an environment that cannot walk a working copy" do
    test "says so instead of reporting an empty one" do
      scope = harness_scope()

      assert {:error, :not_supported_on_harness} =
               Scanner.observe(scope.environment, Files.read_model(scope))
    end

    test "does not delete the rows a harness already reported" do
      {local, tmp_dir} = local_scope()

      write_impl(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      write_impl(tmp_dir, "my_app/billing", "MyApp.Billing")

      {:ok, %{total_files: synced}} = FileSync.sync(local, base_dir: tmp_dir, embed: false)
      assert synced >= 2

      before = Files.list_files(local) |> length()
      assert before >= 2

      # The same project and the same harness, reached through the server's own
      # scope — no working copy on this side. This is the call `get_next_requirement`
      # makes, and it used to return `{:ok, %{removed: 2}}`.
      server = %{local | cwd: nil, environment: Environment.new(:harness, nil)}

      assert {:error, {:cannot_scan, :not_supported_on_harness}} =
               FileSync.sync(server, base_dir: nil, embed: false)

      assert length(Files.list_files(local)) == before
    end
  end

  describe "a working copy that really is empty" do
    # The other half of the same rule, and the reason the fix is not "refuse
    # empty manifests". Deleting a project's last tracked file produces an empty
    # scan that is entirely truthful, and the row has to go — otherwise the
    # server holds files nobody can find, which is the failure the whole-manifest
    # design exists to prevent.
    test "still has its rows removed when the scan succeeds and finds nothing" do
      {scope, tmp_dir} = local_scope()

      path = Path.join([tmp_dir, "lib", "my_app", "only.ex"])
      write_impl(tmp_dir, "my_app/only", "MyApp.Only")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir, embed: false)
      assert length(Files.list_files(scope)) >= 1

      File.rm!(path)

      assert {:ok, %{removed: removed}} = FileSync.sync(scope, base_dir: tmp_dir, embed: false)
      assert removed >= 1
      assert Files.list_files(scope) == []
    end
  end

  defp local_scope do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    {scope, tmp_dir}
  end

  defp harness_scope do
    scope = full_scope_fixture()
    %{scope | cwd: nil, environment: Environment.new(:harness, nil)}
  end

  defp write_impl(tmp_dir, module_path, module_name) do
    impl_path = Path.join([tmp_dir, "lib", "#{module_path}.ex"])
    File.mkdir_p!(Path.dirname(impl_path))

    File.write!(impl_path, """
    defmodule #{module_name} do
      @moduledoc false
    end
    """)
  end
end
