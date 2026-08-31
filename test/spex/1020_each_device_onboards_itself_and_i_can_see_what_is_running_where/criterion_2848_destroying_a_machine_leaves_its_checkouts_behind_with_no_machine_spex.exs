defmodule CodeMySpecSpex.Story1020.Criterion2848Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2848 — Destroying a machine takes its checkouts with it, and leaves
  the record of their work.

  Rule: A device that goes takes its working copies, because a checkout on no
  machine is not a state any more.

  Destroying is a real act for a sprite, and uninstalling CMS from a laptop
  amounts to the same thing: the machine stops existing as far as this system is
  concerned.

  ## Rewritten, and why

  This used to assert the opposite — that the copies survived with `device_id`
  nullified, "landing in the same state as a copy that never reported a
  machine". That state no longer exists. `working_copies.device_id` is required
  now, because a checkout is identified by `{project, device, root}` and two
  machines share a path constantly, so a copy with no machine cannot be told
  apart from one somewhere else.

  The fear that shaped the old version was that a cascade "would take the record
  of work that was really done". It does not, and the tables say so themselves:
  `agents`, `issues`, `problems`, `sessions` and a project's default copy are
  `SET NULL` and survive; `files`, `requirements`, `analysis_runs` and
  `file_analyses` cascade, and every one of those is a projection of a directory
  that has just stopped existing. What is kept is what happened; what goes is a
  description of a disk nobody has.
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
    scenario "Destroying a machine takes its checkouts with it" do
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

      then_ "and its checkouts are gone with it", context do
        {:ok, copies, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        refute has_element?(
                 copies,
                 "[data-test='working-copy'][data-working-copy-id='#{context.copy.working_copy_id}']"
               ),
               "the checkout outlived the machine it was on. There is nowhere for it " <>
                 "to be — a copy is a directory on a box, and the box is gone — so a " <>
                 "row still listing it is offering somewhere to look that is not there."

        {:ok, context}
      end
    end
  end
end
