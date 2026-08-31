defmodule CodeMySpecSpex.Story1020.Criterion2844Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2844 — A machine that did not say what it is is not recorded as one.

  Rule: What a machine has not said is never guessed at.

  `kind` has no default on purpose. A default is a guess, and the guess that
  costs money is the wrong one: a cloud box quietly rendered as somebody's
  laptop is a machine nobody thinks to shut down. The distinction is the one
  thing this field exists for, so inventing it defeats the field.

  ## Rewritten, and why

  This used to assert that an unstated kind rendered as "unknown" on the devices
  page. `devices.kind` is `NOT NULL` now — a machine whose kind nobody knows
  cannot answer the question the column exists for, and everything downstream
  carried a third state forever because of it.

  The rule is untouched: nothing is guessed. What changed is where the answer
  is refused. An announce that does not say what the machine is does not produce
  a row reading "unknown" — it does not produce a row. That reaches only a
  client too old to send a kind, which is the same client whose device-less
  joins are already refused, and for the same reason.
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
    scenario "A machine that did not say what it is is not recorded as one" do
      given_ "a machine about to connect without saying whether it is local or cloud",
             context do
        # `kind: nil` is dropped from the body by the helper, so the machine
        # genuinely says nothing rather than saying "unknown" — a client built
        # before the field existed sends exactly this.
        {:ok, Map.put(context, :quiet, kind: nil, hostname: "a-quiet-machine")}
      end

      when_ "it announces itself", context do
        {:ok, Map.put(context, :reply, announce_response(context, context.quiet))}
      end

      then_ "it is refused rather than filled in", context do
        assert context.reply.status == 422,
               "the announce was accepted, so something decided what this machine is " <>
                 "on its behalf. A default is a guess, and the guess that costs money " <>
                 "is the wrong one: a cloud box rendered as somebody's laptop is a " <>
                 "machine nobody thinks to shut down."

        assert context.reply.resp_body =~ "kind",
               "the refusal does not name the field that was missing, so the operator " <>
                 "cannot tell what their machine failed to send. Got: " <>
                 context.reply.resp_body

        {:ok, context}
      end

      then_ "and it is not on my devices", context do
        {:ok, live, _html} = live(context.conn, "/app/devices")

        refute has_element?(live, "[data-test='device']", "a-quiet-machine"),
               "the machine was refused and is listed anyway"

        {:ok, context}
      end
    end
  end
end
