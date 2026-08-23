defmodule CodeMySpecSpex.Story1020.Criterion2841Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2841 — A machine claiming somebody else's identity does not get it.

  Rule: A device that reconnects is recognised, never duplicated.

  The identity arrives *from a machine*, which makes it an input rather than a
  fact. Every other id on this surface is treated that way already — `issue/3`
  scopes by project, `Devices.get_device/2` refuses to look up unscoped — and
  the reason is that trusting it is not a subtle leak: one account's daemon
  presenting another's id would be handed that account's machine, and with it
  every checkout attached to it.

  It is refused by being *ignored* rather than by erroring. A machine that
  presents an id we do not recognise is in exactly the same position as one that
  presents none — it needs an identity — and issuing it its own is both the
  useful answer and the safe one. That the two cases converge is why this is a
  failure_path on the same rule rather than a rule of its own.
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

  spex "An identity is an input, not a fact" do
    scenario "A machine claiming somebody else's identity does not get it" do
      given_ "an identity belonging to another account's machine", context do
        # A second tenant built the same way the first one was, so the id under
        # test is genuinely another account's rather than a uuid this spec made
        # up. An invented id exercises "unknown", which is a different case.
        other =
          %{conn: Phoenix.ConnTest.build_conn()}
          |> register_log_in_setup_account()
          |> setup_active_project()

        theirs = device_id(other, hostname: "not-your-machine", kind: "cloud")

        {:ok, context |> Map.put(:theirs, theirs) |> Map.put(:other, other)}
      end

      when_ "a machine presents it", context do
        reply =
          announce_device(context,
            device_id: context.theirs,
            hostname: "my-machine",
            kind: "local"
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is not handed that account's device", context do
        refute context.reply["device_id"] == context.theirs,
               "presenting another account's identity was answered with that " <>
                 "account's machine. Every checkout attached to it comes along, " <>
                 "which makes this a tenancy hole rather than a mix-up."

        {:ok, context}
      end

      then_ "and it is issued its own instead", context do
        assert is_binary(context.reply["device_id"]) and context.reply["device_id"] != "",
               "refusing by erroring leaves a real machine with no way to onboard. " <>
                 "An id we do not recognise puts the machine in the same position " <>
                 "as one presenting none, and the useful answer is the safe one."

        {:ok, context}
      end
    end
  end
end
