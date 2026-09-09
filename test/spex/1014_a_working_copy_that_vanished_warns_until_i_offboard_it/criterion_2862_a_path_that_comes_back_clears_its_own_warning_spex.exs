defmodule CodeMySpecSpex.Story1014.Criterion2862Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2862 — A path that comes back clears its own warning.

  Rule: A working copy observed present again is no longer flagged.

  A warning that cannot clear itself stops being information. Volumes get
  unmounted, external disks get pulled, a container's bind mount is not there for
  the first second after it starts — none of those are a checkout being deleted,
  and all of them look identical to one for as long as they last.

  If clearing needed a person, every one of those would leave a permanent warning
  on a copy that is fine, and the page would fill with rows nobody can act on.
  The rows that *do* need acting on would then be the ones nobody notices, which
  is where the warning stops being worth having at all.

  So the flag tracks the latest observation rather than latching on the first bad
  one. What does not reset is `path_missing_since` while it stays missing — see
  the note in `observe_paths/2`. How long it has been gone is the only thing that
  tells an operator whether this was them.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.PathReportHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A warning clears itself when the thing it was about stops being true" do
    scenario "A path that comes back clears its own warning" do
      given_ "a working copy shown as missing because its volume was unmounted", context do
        device = device_id(context, hostname: "the-laptop")

        root = checkout("placeholder")
        joined = join_working_copy(context, root, "the copy on the volume", device_id: device)
        working_copy_id = joined.working_copy_id

        RealDisk.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: working_copy_id, root: root})
        )

        reporter = harness(context, device, %{working_copy_id => root})

        # The volume goes away. Not deleted — unmounted, which from the
        # harness's side is the same `RealDisk.dir?` answer and is the whole reason
        # this criterion exists.
        remove(root)
        report(reporter)

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 live,
                 "[data-working-copy-id='#{working_copy_id}'] [data-test='path-missing']"
               ),
               "the premise is a copy that is currently warned about; without the " <>
                 "warning there is nothing here to clear and this asserts nothing"

        {:ok,
         context
         |> Map.put(:root, root)
         |> Map.put(:working_copy_id, working_copy_id)
         |> Map.put(:reporter, reporter)}
      end

      when_ "its harness next reports the path present", context do
        # The volume is mounted again, with the checkout on it exactly as it was.
        RealDisk.mkdir_p!(context.root)

        RealDisk.write!(
          Path.join(context.root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: context.working_copy_id, root: context.root})
        )

        {:ok, Map.put(context, :observation, report(context.reporter))}
      end

      then_ "the copy is no longer shown as missing", context do
        assert context.observation[context.working_copy_id] == true,
               "the harness is still reporting the path gone after it came back. " <>
                 "Got: #{inspect(context.observation)}"

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        refute has_element?(
                 live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='path-missing']"
               ),
               "the checkout is back and the page still says it is gone. A flag " <>
                 "that latches turns every unmounted volume into a permanent " <>
                 "warning on a copy that is fine, which is how the rows that do " <>
                 "need acting on become the ones nobody notices."

        {:ok, Map.put(context, :live, live)}
      end

      then_ "and nobody had to clear the warning by hand", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.working_copy_id}']"
               ),
               "the copy is not on the list at all, so the warning cleared by the " <>
                 "copy being removed rather than by the path coming back — which " <>
                 "is the one way of passing the assertion above that would be worse " <>
                 "than failing it"

        {:ok, context}
      end
    end
  end
end
