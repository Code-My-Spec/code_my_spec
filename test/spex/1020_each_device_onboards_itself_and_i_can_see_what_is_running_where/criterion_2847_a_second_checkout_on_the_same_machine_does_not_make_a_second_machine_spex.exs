defmodule CodeMySpecSpex.Story1020.Criterion2847Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2847 — A second checkout on the same machine does not make a second
  machine.

  Rule: A cms harness onboards its device when it comes up, from a file
  belonging to the install rather than to any working copy.

  The failure this rules out is the design `fceda276` actually shipped:
  announcing on the working-copy join. One install serves many checkouts —
  eight worktrees on this laptop alone — so a per-copy announce mints a machine
  per checkout and the device list becomes a slower copy of the working-copy
  list, which is the thing it exists to summarise.

  So a second checkout attaches to the machine already there. The identity
  belongs to the install; a checkout can only report which install it is under,
  never create one.
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

  spex "One install stays one machine however many checkouts it serves" do
    scenario "A second checkout on the same machine does not make a second machine" do
      given_ "a machine already onboarded, serving one checkout", context do
        id = device_id(context, hostname: "one-laptop", kind: "local")

        first =
          join_working_copy(context, "/tmp/spex-1020-first", "first checkout", device_id: id)

        {:ok, live, _html} = live(context.conn, "/app/devices")
        rows = live |> element("[data-test='devices']") |> render()
        before = rows |> String.split("data-test=\"device\"") |> length() |> Kernel.-(1)

        {:ok,
         context
         |> Map.put(:device_id, id)
         |> Map.put(:first, first)
         |> Map.put(:before, before)}
      end

      when_ "a second checkout on that same machine starts being served", context do
        second =
          join_working_copy(context, "/tmp/spex-1020-second", "second checkout",
            device_id: context.device_id
          )

        {:ok, live, _html} = live(context.conn, "/app/devices")

        {:ok, context |> Map.put(:second, second) |> Map.put(:live, live)}
      end

      then_ "it attaches to the machine that is already there", context do
        {:ok, copies, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 copies,
                 "[data-test='working-copy'][data-working-copy-id='#{context.second.working_copy_id}'] [data-test='working-copy-device'][data-device-id='#{context.device_id}']"
               ),
               "the second checkout did not land on the machine that was already " <>
                 "serving the first one"

        {:ok, context}
      end

      then_ "and no second machine appears", context do
        rows = context.live |> element("[data-test='devices']") |> render()
        count = rows |> String.split("data-test=\"device\"") |> length() |> Kernel.-(1)

        # One machine *for this checkout pair*, not one on the account. The
        # account arrives holding a machine of its own now: `device_id` is
        # required on a working copy, so the fixture that mints this scope's
        # checkout mints a device for it too. What this claims is unchanged —
        # serving a second checkout added nothing.
        assert count == context.before,
               "serving two checkouts took the list from #{context.before} machines " <>
                 "to #{count}. One install " <>
                 "serves many checkouts — eight worktrees on this laptop alone — " <>
                 "so a machine per checkout makes the device list a slower copy of " <>
                 "the list it exists to summarise."

        {:ok, context}
      end
    end
  end
end
