defmodule CodeMySpecSpex.PathReportHelpers do
  @moduledoc """
  The surface story 892's criteria establish path presence through.

  A harness on a machine, holding some checkouts, saying which of them are still
  there. Six criteria need it, so it lives here rather than six times over.

  ## Nothing is faked between the checkout and the row

  `report/1` runs `CmsHarness.WorkingCopyReporter.report/1`, which stats the real
  directories, hands the result to `CmsHarness.Device.announce/1`, which posts it
  through `CodeMySpecTest.InProcessDeviceClient` to the real `DeviceController`,
  which calls the real `WorkingCopies.observe_paths/2`. The only thing removed is
  the socket.

  That matters here more than usual. The behaviour under test *is* "the machine
  looked and told us", so a helper that wrote `path_missing_since` directly would
  assert that the column can be set — which was never in doubt — while leaving
  every interesting question (does a vanished config file read as missing? does
  one device speak for another's copies?) untested.

  ## Real directories, removed for real

  `remove/1` is `File.rm_rf!`. The criterion is about a worktree being deleted,
  and deleting it is cheap, so there is no reason to approximate.
  """

  import ExUnit.Assertions

  alias CmsHarness.WorkingCopyReporter
  alias CodeMySpec.TempFile
  alias CodeMySpecSpex.Fixtures

  @doc """
  A checkout on disk: a real directory carrying a real `.cms_harness.json`.

  The config file is what `CmsHarness.WorkingCopies.all/0` reads, so writing it
  is how a directory becomes a checkout the harness can discover — and removing
  the directory is how it stops being one, taking the file with it. That is the
  whole mechanism the reporter has to survive.
  """
  @spec checkout(String.t()) :: String.t()
  def checkout(working_copy_id) do
    root = TempFile.dir("spex_892_copy")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, ".cms_harness.json"),
      Jason.encode!(%{working_copy_id: working_copy_id, root: root}, pretty: true)
    )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  @doc "Delete a checkout, the way `git worktree remove` does."
  @spec remove(String.t()) :: :ok
  def remove(root) do
    File.rm_rf!(root)

    refute File.dir?(root),
           "the premise is a checkout that is gone; #{root} is still there, so " <>
             "this would assert nothing"

    :ok
  end

  @doc """
  A harness running on `device_id`, serving `copies` (`%{id => root}`).

  Puts the device identity where `CmsHarness.Device` looks for it and the
  credential where it looks for that, then starts a reporter seeded with the
  copies this harness has served. Returns the reporter, which `report/1` takes.

  The identity file goes somewhere disposable rather than at
  `~/.codemyspec/device.json` — the same seam story 1020's criterion 2846 uses,
  and for the same reason: a spec must not write to the machine it runs on.
  """
  @spec harness(map(), String.t(), %{optional(String.t()) => String.t()}) :: map()
  def harness(context, device_id, copies) do
    file = device_file(device_id)
    put_credential(context)

    name = Module.concat(WorkingCopyReporter, "Spex#{System.unique_integer([:positive])}")

    {:ok, pid} =
      ExUnit.Callbacks.start_supervised(
        Supervisor.child_spec({WorkingCopyReporter, name: name, known: copies}, id: name)
      )

    %{device_id: device_id, reporter: pid, device_file: file}
  end

  @doc """
  The harness looks and tells the server what it found.

  Returns the observation it sent, so a criterion can assert on what was claimed
  as well as on what the page then says.

  Points the identity env at *this* harness's file first. `CmsHarness.Device`
  reads that from application env, which is global — so with two harnesses in
  one criterion, whichever started last would otherwise own the identity and
  both would announce as the same machine. That is precisely the criterion about
  telling two machines apart, so the trap is worth closing here rather than
  documenting as an ordering rule every caller has to remember.
  """
  @spec report(map()) :: %{optional(String.t()) => boolean()}
  def report(%{reporter: reporter, device_file: file}) do
    Application.put_env(:code_my_spec, :device_config_path, file)
    WorkingCopyReporter.report(reporter)
  end

  # Where this machine's identity is kept, somewhere disposable — the same seam
  # story 1020's criterion 2846 uses, so a spec never writes to
  # `~/.codemyspec/device.json` on the machine it happens to run on.
  defp device_file(device_id) do
    dir = TempFile.dir("spex_892_install")
    File.mkdir_p!(dir)
    file = Path.join(dir, "device.json")
    File.write!(file, Jason.encode!(%{device_id: device_id}))

    previous = Application.get_env(:code_my_spec, :device_config_path)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :device_config_path, previous)
      File.rm_rf(dir)
    end)

    file
  end

  # The credential a machine holds. A project deploy key rather than a user's
  # session, because a sprite has no signed-in user and the route has to work
  # for one — the same argument `DeviceHelpers` makes.
  defp put_credential(context) do
    key = "dk_spex_892_#{:erlang.phash2(context.project.id)}"
    Fixtures.set_project_deploy_key(context.scope, context.project, key)

    previous = Application.get_env(:code_my_spec, :harness_token)
    Application.put_env(:code_my_spec, :harness_token, key)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :harness_token, previous)
    end)
  end
end
