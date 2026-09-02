defmodule CodeMySpecSpex.Story1043.Criterion3060Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3060 — A new finding starts the count again.

  Rule: An agent told the same thing it could not act on is eventually left
  alone.

  The other half of the escape, and the half that keeps it from becoming a
  muzzle. Falling silent about a finding the agent cannot fix is right; staying
  silent about everything afterwards is not. An agent that broke something new
  while ignoring something old still needs telling about the new thing.

  The distinction is what the count is keyed on. The external path counts
  consecutive deliveries of the same **blocking key** — a finding set rather
  than a rendered string, which is what `Validation.blocking_key/1` exists for
  and why R8's escape did not fire on the text changing. A different finding is
  a different key, and a different key is a fresh count.

  Get this wrong in the cheap direction — count deliveries rather than
  identities — and the agent goes quiet permanently after N stops, whatever the
  tree does next.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent told the same thing it could not act on is eventually left alone" do
    scenario "A new finding starts the count again" do
      given_ "an agent left alone over a finding it could not fix", context do
        # Story 988's criterion 8201's recipe; `fresh_analysis_runs/2` is what
        # makes a finding block rather than merely be reported.
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        Fixtures.record_problem(context.scope, "credo", %{file_path: @impl_path})
        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        agent_id = running_agent(context)
        for _ <- 1..8, do: :ok = Fixtures.end_turn(context.scope, agent_id)

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:quiet_at, length(Fixtures.orchestrator_actions(context.scope, agent_id)))}
      end

      when_ "a run lands with a finding it has not been told about", context do
        # A different file and a different message, so a different finding set —
        # the thing the blocking key is computed from.
        # The file has to exist before a finding on it means anything — a
        # problem naming a path the project has never seen is not a finding
        # about this tree.
        :ok =
          Environments.write_file(
            context.environment,
            "lib/something_else.ex",
            "defmodule SomethingElse do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        Fixtures.record_problem(context.scope, "credo", %{
          file_path: "lib/something_else.ex",
          message: "Function is too complex"
        })

        # Fresh again, for the same reason as the premise: a finding on a stale
        # source is reported and not enforced, so without this the "new finding"
        # could not wake anything either and the scenario would assert the
        # escape had failed when nothing had been enforceable.
        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok,
         Map.put(
           context,
           :told,
           Fixtures.orchestrator_actions(context.scope, context.agent_id)
         )}
      end

      then_ "the agent is woken", context do
        assert length(context.told) > context.quiet_at, """
        The agent broke something new and heard nothing, because it had already
        been left alone over something old. Falling silent about an unfixable
        finding is the escape working; falling silent about everything after it
        is the escape becoming a muzzle.

        told when it went quiet: #{context.quiet_at}, now: #{length(context.told)}
        """

        assert List.last(context.told) =~ "something_else",
               "the agent was woken, but not about the new finding: #{inspect(context.told)}"

        {:ok, context}
      end
    end
  end
end
