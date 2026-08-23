defmodule CodeMySpecSpex.Story1020.Criterion2849Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2849 — A machine that is online says so even when nothing is running
  on it.

  Rule: A device is present when its harness is connected, which is a different
  question from whether a checkout still exists on it.

  Three liveness questions sit in a chain and only the middle one has ever been
  built:

    * a **device** is present when its harness holds a connection
    * a **working copy** is present when its path still exists on that device
    * an **agent** is present when its lane is joined and working

  Collapsing them is how a page ends up saying something it cannot know. Story
  957 already produced that bug twice — `Liveness` calling a `:starting` agent
  "Running · present on the harness channel", and `chattable?` offering a chat to
  a lane that had never confirmed — both from reading one signal as another.

  A quiet machine and an unreachable one are the case this criterion protects.
  Both have nothing running; only one of them can still be reached, and a page
  that reports only agent activity cannot tell you which you are looking at.
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

  spex "The box being on is its own fact" do
    scenario "A machine that is online says so even when nothing is running on it" do
      given_ "a machine whose harness is connected, with no agent running anywhere on it",
             context do
        id = device_id(context, hostname: "an-idle-but-live-machine", kind: "local")
        join_working_copy(context, "/tmp/spex-1020-quiet", "a quiet checkout", device_id: id)

        # Deliberately no agents reported. The machine is up; nothing is at work.
        {:ok, Map.put(context, :device_id, id)}
      end

      when_ "I look at my devices", context do
        {:ok, live, _html} = live(context.conn, "/app/devices")

        row =
          live
          |> element("[data-test='device'][data-device-id='#{context.device_id}']")
          |> render()

        {:ok, context |> Map.put(:live, live) |> Map.put(:row, row)}
      end

      then_ "the machine reads as present", context do
        assert has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.device_id}'] [data-test='device-presence']"
               ),
               "the machine says nothing about whether it can be reached. A quiet " <>
                 "box and an unreachable one look identical without it, and only " <>
                 "one of them is a problem."

        assert context.row =~ ~r/present|online|connected/i,
               "the machine is connected and the row does not say so. Got: #{context.row}"

        {:ok, context}
      end

      then_ "and that is not confused with anything being at work on it", context do
        refute context.row =~ ~r/\brunning\b|\bworking\b|\bbusy\b/i,
               "the row reports the box being on as though something were happening " <>
                 "on it. Those are two facts — story 957 shipped this exact " <>
                 "conflation twice, calling a :starting agent 'Running · present on " <>
                 "the harness channel'. Got: #{context.row}"

        {:ok, context}
      end
    end
  end
end
