defmodule CodeMySpecSpex.Story1020.Criterion2848Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2848 — Destroying a machine leaves its checkouts behind, with no
  machine.

  Rule: A device that goes leaves its working copies behind, orphaned rather
  than deleted — and an orphan is indistinguishable from a copy that never
  reported one.

  Destroying is a real act for a sprite, and uninstalling CMS from a laptop
  amounts to the same thing: the machine stops existing as far as this system is
  concerned, while the checkouts it served remain facts that happened. A cascade
  delete would take the record of work that was really done because the box it
  sat on went away.

  So the copies survive with `device_id` nullified, landing in the same state as
  a copy that never reported a machine — which is why this scenario and 2845
  assert the same rendered outcome by two different routes. That convergence is
  the model being right rather than a duplicate.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A machine going does not take the record of its work with it" do
    scenario "Destroying a machine leaves its checkouts behind, with no machine" do
      given_ "a machine with checkouts on it", context do
        id = device_id(context, hostname: "a-doomed-sprite", kind: "cloud")
        copy = join_working_copy(context, "/tmp/spex-1020-doomed", "a checkout", device_id: id)

        {:ok, context |> Map.put(:device_id, id) |> Map.put(:copy, copy)}
      end

      when_ "the machine is destroyed, or CMS is simply uninstalled from it", context do
        {:ok, live, _html} = live(context.conn, "/app/devices")

        html =
          live
          |> element(
            "[data-test='device'][data-device-id='#{context.device_id}'] [data-test='destroy-device']"
          )
          |> render_click()

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "the machine goes from my devices", context do
        refute has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.device_id}']"
               ),
               "the machine was destroyed and is still listed as one of mine"

        {:ok, context}
      end

      then_ "and its checkouts are still listed, now saying their machine is not known",
            context do
        {:ok, copies, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        row =
          copies
          |> element(
            "[data-test='working-copy'][data-working-copy-id='#{context.copy.working_copy_id}']"
          )
          |> render()

        assert row =~ ~r/no machine|machine (is )?not known|orphan/i,
               "the checkout survived its machine and does not say so. It lands " <>
                 "in the same state as a copy that never reported one, and the " <>
                 "row has to describe that rather than stay silent. Got: #{row}"

        refute row =~ context.device_id,
               "the checkout still points at a machine that no longer exists"

        {:ok, context}
      end
    end
  end
end
