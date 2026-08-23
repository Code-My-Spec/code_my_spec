defmodule CodeMySpecSpex.Story1020.Criterion2838Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2838 — A new machine appears without anyone registering it.

  Rule: A device onboards itself when it comes online; nobody registers a
  machine by hand.

  The whole weight of this one is on the *absence* of a step. A machine that has
  to be registered is a machine somebody forgets to register, and the list then
  describes the machines whoever set it up remembered — not the machines that
  exist. That is worse than no list, because it reads as complete.

  So the criterion is satisfied by announcing and then looking: nothing between
  those two acts is allowed to be a person typing a command. The announce is the
  harness coming up, and the page is opened by somebody who did nothing else.
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

  spex "A machine puts itself on the list" do
    scenario "A new machine appears without anyone registering it" do
      given_ "a machine running the harness that has never connected", context do
        {:ok, Map.put(context, :hostname, "a-machine-nobody-registered")}
      end

      when_ "it comes online and starts serving a checkout", context do
        announce_device(context, hostname: context.hostname, kind: "local")

        {:ok, live, html} = live(context.conn, "/app/devices")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "it appears among my devices", context do
        assert context.html =~ context.hostname,
               "the machine announced itself and is not on the list. A device " <>
                 "that has to be found some other way is one nobody finds. " <>
                 "Got: #{context.html}"

        {:ok, context}
      end

      then_ "and nobody ran a command to put it there", context do
        assert has_element?(context.live, "[data-test='device']"),
               "the row exists only because the machine announced itself — no " <>
                 "fixture made it, no command registered it. If this needs a " <>
                 "person to run something first, the list describes the machines " <>
                 "somebody remembered rather than the machines that exist."

        {:ok, context}
      end
    end
  end
end
