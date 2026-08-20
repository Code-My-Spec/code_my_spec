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

    # `sync_changed/2` is the stop hook's path and the one that actually fired
    # in production — four minutes after `sync/2` was fixed, on a healthy
    # harness: `0 files scanned in 0ms … 3937 removed`. Fixing `sync/2` alone
    # left the hotter of the two callers doing exactly what it always had.
    #
    # `cwd` is set here on purpose. It is what the hook's `x-working-dir` header
    # produces, so it does not mean a walkable tree is present, and
    # `Validation`'s `cwd: nil` guard therefore never caught this.
    test "the stop hook's changed-file scan refuses too" do
      {local, tmp_dir} = local_scope()

      write_impl(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      {:ok, _} = FileSync.sync(local, base_dir: tmp_dir, embed: false)

      before = Files.list_files(local) |> length()
      assert before >= 1

      server = %{local | environment: Environment.new(:harness, nil)}

      assert {:error, {:cannot_scan, :not_supported_on_harness}} =
               FileSync.sync_changed(server, base_dir: tmp_dir)

      assert length(Files.list_files(local)) == before
    end

    # The refusal is right and permanent for this environment, which is exactly
    # why it must not be an error.
    #
    # `Environments.Harness.stream_files/3` returns `:not_supported_on_harness`
    # unconditionally — a working copy on another machine has no disk here — so
    # a harness-backed copy takes this branch on every stop hook. Logged at
    # `:error` it produced 197 error-level lines in one `web.log`, and made the
    # top four entries by volume in that file this and its consequences; finding
    # a real error in there meant bucketing by message shape first.
    #
    # Asserted on the decision rather than through `CaptureLog`, because the
    # suite pins the global Logger at `:warning`: an `:info` line never reaches
    # the capture handler, so a log-based test of the quiet branch would assert
    # only that nothing was captured — which is just as true of a line nobody
    # writes. That is the shape this file exists to complain about.
    test "the structural refusal is reported, but not as an error" do
      assert FileSync.scan_refusal_level(:not_supported_on_harness) == :info,
             "a condition that holds for every stop hook on this environment is a " <>
               "property, not an event, and an error nobody can act on is how real " <>
               "errors get skipped"

      assert FileSync.scan_refusal_level(:enoent) == :error,
             "a scan that failed for any other reason is an event and still deserves " <>
               "the level — this must not become a blanket downgrade"
    end

    # The level moved; nothing else did. `scannable/1` folded this refusal into
    # `[]` and deleted 3936 rows and 452 Problems, twice, because "could not
    # look" reached the caller as "nothing is there". Quieting a log line is
    # safe; letting the caller believe the scan happened is what was not.
    test "quieting the log did not quiet the refusal" do
      {local, tmp_dir} = local_scope()

      write_impl(tmp_dir, "my_app/accounts", "MyApp.Accounts")
      {:ok, _} = FileSync.sync(local, base_dir: tmp_dir, embed: false)

      before = Files.list_files(local) |> length()
      assert before >= 1

      server = %{local | environment: Environment.new(:harness, nil)}

      assert {:error, {:cannot_scan, :not_supported_on_harness}} =
               FileSync.sync_changed(server, base_dir: tmp_dir)

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
      refute Files.list_files(scope) == []

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
