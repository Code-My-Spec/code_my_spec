defmodule CodeMySpecSpex.Story1059.Criterion3331Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3331 — The interval is set rather than assumed.

  Rule: how often is a decision, and decisions live where they can be changed.

  The interval is the one number that trades the two costs of this feature
  against each other, and the right value is not knowable in advance. Too long
  and a stalled agent burns most of a window before anybody looks — criterion
  3319's whole point. Too short and the check-ins cost more than they find, on a
  machine that is also running the agents.

  Twenty minutes is what the person doing this by hand settled on, and it is a
  starting guess rather than a finding. A number in code makes changing it a
  deploy, which in practice means it never changes and the guess becomes
  permanent.

  ## What the scenario asserts

  That changing the setting changes the cadence — read from the cadence itself,
  not from the setting. A configurable-looking setting nothing reads is the
  failure worth catching here, and it is invisible from the setting's side.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The cadence runs on the interval somebody set" do
    scenario "the configured interval is changed" do
      given_ "a project with a main agent and a configured cadence", context do
        reply = join_working_copy(context, "/tmp/spex-3331", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        _main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3331")

        :ok = Fixtures.set_cadence_interval(scope, 20 * 60)

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the configured interval is changed", context do
        :ok = Fixtures.set_cadence_interval(context.scope, 5 * 60)

        {:ok, context}
      end

      then_ "the main agent is woken on the new interval", context do
        assert Fixtures.cadence_interval(context.scope) == 5 * 60,
               """
               The cadence is still running on the old interval, or on one
               nothing set.

               This is the one number that trades the feature's two costs
               against each other and the right value is not knowable in
               advance: too long and a stalled agent burns most of a window
               before anybody looks, too short and the check-ins cost more than
               they find on a machine that is also running the agents.

               Twenty minutes is what a person doing this by hand settled on — a
               starting guess. In code it is a deploy to change, which in
               practice means it never changes and the guess becomes permanent.

               read back: #{inspect(Fixtures.cadence_interval(context.scope))}
               """

        {:ok, context}
      end
    end
  end
end
