defmodule CodeMySpecSpex.Story1020.Criterion2846Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2846 — Starting the harness is what onboards the machine.

  Rule: A cms harness onboards its device when it comes up, from a file
  belonging to the install rather than to any working copy.

  The grain is the point. `fceda276` announced the device on the working-copy
  join, which makes a machine appear only once it has a checkout on it — but a
  machine is a machine whether or not it does, and one install serves many
  checkouts. Boot is the moment there is exactly one of.

  The file belongs beside the install (`~/.codemyspec/device.json`, next to
  `harness_secret`) rather than inside a checkout, and that placement earns
  something concrete: a device id cannot be cloned. `.cms_harness.json` lives in
  the repository and *is* clonable, which is the failure story 891's criterion
  2353 exists for.

  Driven through `CmsHarness.Device.announce/0` — the harness's own boot entry
  point, the same way `join_working_copy/4` drives a real channel join rather
  than reaching past it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The machine onboards because the harness came up" do
    scenario "Starting the harness is what onboards the machine" do
      given_ "a machine with a cms harness installed and no device file", context do
        dir =
          Path.join(System.tmp_dir!(), "spex-1020-install-#{System.unique_integer([:positive])}")

        RealDisk.mkdir_p!(dir)
        on_exit(fn -> RealDisk.rm_rf(dir) end)

        file = Path.join(dir, "device.json")
        previous = Application.get_env(:code_my_spec, :device_config_path)
        Application.put_env(:code_my_spec, :device_config_path, file)
        on_exit(fn -> Application.put_env(:code_my_spec, :device_config_path, previous) end)

        refute RealDisk.exists?(file),
               "the premise is a machine that has never onboarded; a file here " <>
                 "would make this assert nothing"

        # The credential a real machine holds. A sprite has no signed-in user at
        # all — only its project's deploy key — and that is the case this route
        # has to work for, so it is the one the premise establishes.
        key = "dk_spex_2846_#{System.unique_integer([:positive])}"
        CodeMySpecSpex.Fixtures.set_project_deploy_key(context.scope, context.project, key)

        previous_token = Application.get_env(:code_my_spec, :harness_token)
        Application.put_env(:code_my_spec, :harness_token, key)
        on_exit(fn -> Application.put_env(:code_my_spec, :harness_token, previous_token) end)

        {:ok, Map.put(context, :device_file, file)}
      end

      when_ "the harness starts", context do
        result = CmsHarnessTest.Machine.announce()

        {:ok, Map.put(context, :result, result)}
      end

      then_ "it is issued an identity and writes it beside the install", context do
        assert {:ok, %{device_id: device_id}} = context.result

        assert RealDisk.exists?(context.device_file),
               "the harness onboarded and wrote nothing down, so its next start " <>
                 "asks for another identity and every restart is a new machine"

        assert RealDisk.read!(context.device_file) =~ device_id,
               "the file does not carry the identity that was issued. It lives " <>
                 "beside the install rather than in a checkout precisely so it " <>
                 "survives restarts and cannot be cloned — a file that holds the " <>
                 "wrong thing does neither."

        {:ok, Map.put(context, :device_id, device_id)}
      end

      then_ "and the machine appears among my devices before it serves any checkout",
            context do
        {:ok, live, _html} = live(context.conn, "/app/devices")

        assert has_element?(
                 live,
                 "[data-test='device'][data-device-id='#{context.device_id}']"
               ),
               "no checkout has been joined, and the machine still has to be on " <>
                 "the list — a machine is a machine whether or not it happens to " <>
                 "have a working copy on it"

        {:ok, context}
      end
    end
  end
end
