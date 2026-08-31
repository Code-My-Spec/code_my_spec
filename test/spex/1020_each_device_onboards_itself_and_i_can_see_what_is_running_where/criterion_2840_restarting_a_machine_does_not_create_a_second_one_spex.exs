defmodule CodeMySpecSpex.Story1020.Criterion2840Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2840 — Restarting a machine does not create a second one.

  Rule: A device that reconnects is recognised, never duplicated.

  A harness restarts constantly — `just refresh` alone does it several times a
  session — so "recognised on reconnect" is not an edge case, it is the ordinary
  path. Get it wrong and the list gains a row every restart until it is
  unreadable, which is exactly the state the working-copies page is in today:
  105 rows, five groups of them byte-identical, because a checkout joining
  without its id is minted another.

  Asserted on the list rather than on the reply, because a reply that returns
  the same id while the list grows would still be a broken product. What matters
  is what somebody looking at their machines sees.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp device_rows(live) do
    live
    |> element("[data-test='devices']")
    |> render()
    |> String.split("data-test=\"device\"")
    |> length()
    |> Kernel.-(1)
  end

  spex "One machine stays one machine" do
    scenario "Restarting a machine does not create a second one" do
      given_ "a machine already among my devices", context do
        id = device_id(context, hostname: "the-restarting-machine", kind: "local")

        {:ok, live, _html} = live(context.conn, "/app/devices")

        assert has_element?(live, "[data-test='device']"),
               "the machine has to be on the list before restarting it means anything"

        {:ok,
         context
         |> Map.put(:device_id, id)
         |> Map.put(:live, live)
         |> Map.put(:before, device_rows(live))}
      end

      when_ "its harness restarts and reconnects", context do
        announce_device(context,
          device_id: context.device_id,
          hostname: "the-restarting-machine",
          kind: "local"
        )

        {:ok, live, html} = live(context.conn, "/app/devices")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "it is the same machine", context do
        assert has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.device_id}']"
               ),
               "the machine came back under a different identity, so everything " <>
                 "recorded against the old one is orphaned while the box is still there"

        {:ok, context}
      end

      then_ "and my list does not grow", context do
        count = device_rows(context.live)

        # Measured as a change rather than against one. The account arrives
        # holding a machine of its own — `working_copies.device_id` is required,
        # so the fixture that mints this scope's checkout mints a device for it
        # — and what this criterion claims is unaffected by that: restarting
        # adds nothing.
        assert count == context.before,
               "restarting took the list from #{context.before} machines to #{count}. " <>
                 "A list that gains a row on every restart is one nobody can read " <>
                 "after a week — which is the state the working-copies list is " <>
                 "already in."

        {:ok, context}
      end
    end
  end
end
