defmodule CodeMySpecSpex.Story1020.Criterion2858Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2858 — A shared dev box onboards without belonging to anyone.

  Rule: A machine announces itself without naming a project, and a shared box
  belongs to no account at all.

  Two halves, and they are reachable at different levels today.

  **No project** is the half this exercises end to end. Nothing in the request
  names one — no project id, no header, no path segment — and the machine is
  still issued an identity. That is not incidental: a machine announces before
  it has a checkout, which is the whole reason this is a route rather than the
  `harness_project:` channel.

  **No account** is exercised in `CodeMySpec.DevicesTest`, at the context, and
  the reason is worth stating rather than hiding. `Plugs.DeployKeyOrOAuth`
  accepts a deploy key or a user's token, and both resolve to an account — so
  there is no credential today that reaches this route and yields an accountless
  scope. `Devices.announce/3` takes one and stores it, which is what makes a
  shared box possible; a *route* that produces one does not exist yet.

  Flagged rather than faked. Writing an unauthenticated announce to make this
  green would let anyone create devices, and asserting it against a stub would
  assert nothing.
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

  spex "A machine onboards without naming what it is for" do
    scenario "A shared dev box onboards without belonging to anyone" do
      given_ "a shared development box running a harness, with no project checked out",
             context do
        {:ok, live, _html} = live(context.conn, "/app/devices")

        # By hostname, not by the list being empty. The account is not empty any
        # more — `working_copies.device_id` is required, so the fixture that
        # mints this scope's checkout mints a machine for it — and the claim was
        # never about the account. It is about *this* box never having
        # announced.
        refute has_element?(live, "[data-test='device']", "the-shared-box"),
               "the premise is a box that has never announced, and one calling " <>
                 "itself the-shared-box is already here"

        {:ok, context}
      end

      when_ "its harness comes up and announces", context do
        reply = announce_device(context, hostname: "a-shared-box", kind: "local")

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is issued an identity like any other machine", context do
        assert is_binary(context.reply["device_id"]) and context.reply["device_id"] != "",
               "a box with nothing checked out on it announced and was told " <>
                 "nothing. A machine exists before anybody's work is on it."

        {:ok, context}
      end

      then_ "and nothing forced it to claim a project to get one", context do
        {:ok, live, _html} = live(context.conn, "/app/devices")

        assert has_element?(
                 live,
                 "[data-test='device'][data-device-id='#{context.reply["device_id"]}']"
               ),
               "the machine is not on the list. Nothing in the announce named a " <>
                 "project — no id, no header, no path segment — and it still has " <>
                 "to be a machine, because it announces before it has a checkout."

        {:ok, context}
      end
    end
  end
end
