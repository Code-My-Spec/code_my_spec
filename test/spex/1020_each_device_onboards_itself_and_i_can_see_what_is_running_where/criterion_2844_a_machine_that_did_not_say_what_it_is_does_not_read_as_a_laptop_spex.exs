defmodule CodeMySpecSpex.Story1020.Criterion2844Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2844 — A machine that did not say what it is does not read as a
  laptop.

  Rule: What a machine has not said reads as unknown, never as a guess.

  `kind` has no default on purpose. A default is a guess, and the guess that
  costs money is the wrong one: a cloud box quietly rendered as somebody's
  laptop is a machine nobody thinks to shut down. The distinction is the one
  thing this field exists for, so inventing it defeats the field.

  It also has to say *something*. A blank cell reads as a rendering bug, and
  somebody debugging the page instead of reading it is the failure one step over
  — the same reason `Liveness` says "Idle · no agent reported on this copy"
  rather than leaving the row empty.
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

  spex "An unanswered question is not answered on the machine's behalf" do
    scenario "A machine that did not say what it is does not read as a laptop" do
      given_ "a machine that connected without saying whether it is local or cloud",
             context do
        # `kind: nil` is dropped from the body by the helper, so the machine
        # genuinely says nothing rather than saying "unknown" — a client built
        # before the field existed sends exactly this.
        id = device_id(context, hostname: "a-quiet-machine", kind: nil)

        {:ok, Map.put(context, :device_id, id)}
      end

      when_ "I look at it", context do
        {:ok, live, html} = live(context.conn, "/app/devices")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "it reads as unknown", context do
        row =
          context.live
          |> element("[data-test='device'][data-device-id='#{context.device_id}']")
          |> render()

        assert row =~ ~r/unknown/i,
               "the machine said nothing about what it is and the row says nothing " <>
                 "either. A blank cell reads as a rendering bug, and somebody " <>
                 "debugging the page instead of reading it is the next failure over. " <>
                 "Got: #{row}"

        {:ok, Map.put(context, :row, row)}
      end

      then_ "and it is not described as local", context do
        refute context.row =~ ~r/\blocal\b/i,
               "a machine that never said what it is was rendered as a laptop. " <>
                 "That is the guess that costs money: a cloud box shown as local " <>
                 "is one nobody thinks to shut down. Got: #{context.row}"

        refute has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.device_id}'][data-kind='local']"
               ),
               "the row carries data-kind='local' for a machine that reported no kind"

        {:ok, context}
      end
    end
  end
end
