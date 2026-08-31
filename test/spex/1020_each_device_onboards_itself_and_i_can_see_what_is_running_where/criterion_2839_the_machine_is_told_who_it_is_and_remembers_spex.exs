defmodule CodeMySpecSpex.Story1020.Criterion2839Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2839 — The machine is told who it is, and remembers.

  Rule: The server issues a device its identity; the machine never invents one.

  Two halves, and the second is the one that bites. Being *issued* an id is
  easy; **keeping** it is what makes the next start the same machine rather than
  a second one. A machine that announces and forgets produces a new row every
  boot, which is the failure the working-copy level already has when a checkout
  joins without its file.

  Why the server issues it at all: every client-derived identity fails the case
  that matters. A hostname is generated for exactly the containers that would
  collide, a MAC address does not survive a re-image, and a path is not identity
  — the same argument that put `WorkingCopies.issue/3` on the server, one level
  up.

  The memory is asserted through the machine's own behaviour rather than by
  reading a file: it presents what it holds on the next announce, and the answer
  says whether it held anything.
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

  spex "An identity comes from the server and stays with the machine" do
    scenario "The machine is told who it is, and remembers" do
      given_ "a machine that has never connected", context do
        # Established by looking rather than assumed. "Never connected" is a
        # claim about the state of the world, and a spec that assumes it passes
        # just as happily against an account that already has ten machines —
        # where "the server issues an identity" would be indistinguishable from
        # "it handed back one that was already there".
        {:ok, live, _html} = live(context.conn, "/app/devices")

        # By hostname, not by the list being empty. The account is not empty any
        # more — `working_copies.device_id` is required, so the fixture that
        # mints this scope's checkout mints a machine for it — and the claim was
        # never about the account. It is about *this* machine never having
        # connected, which is what makes "the server issues an identity"
        # distinguishable from "it handed back one that was already there".
        refute has_element?(live, "[data-test='device']", "a-machine"),
               "the premise is a machine that has never connected, and one calling " <>
                 "itself a-machine is already here"

        {:ok, Map.put(context, :live, live)}
      end

      when_ "it announces itself", context do
        issued = announce_device(context, hostname: "a-machine", kind: "local")

        {:ok, Map.put(context, :issued, issued)}
      end

      then_ "the server issues it an identity", context do
        assert is_binary(context.issued["device_id"]) and context.issued["device_id"] != "",
               "the machine announced and was told nothing. It has no identity it " <>
                 "could have derived — a generated hostname collides for exactly " <>
                 "the containers that matter — so an announce that answers with " <>
                 "no id leaves the machine unable to be anything. " <>
                 "Got: #{inspect(context.issued)}"

        {:ok, context}
      end

      then_ "and the machine keeps it, so its next start is the same machine",
            context do
        again =
          announce_device(context,
            device_id: context.issued["device_id"],
            hostname: "a-machine",
            kind: "local"
          )

        assert again["device_id"] == context.issued["device_id"],
               "presenting the identity it was issued got a different one back. " <>
                 "Then nothing the machine writes down is worth writing down, and " <>
                 "every boot is a new machine."

        {:ok, context}
      end
    end
  end
end
