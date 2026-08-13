defmodule CodeMySpecSpex.Story1013.Criterion2356Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2356 — Onboarding twice is the same as onboarding once.

  Rule: Running onboarding a second time changes nothing.

  Idempotence is what makes the command safe to reach for. An agent that is unsure
  whether a working copy was onboarded should be able to run it and find out,
  rather than reason about it — and it will only do that if running it twice is
  known to be harmless.

  The identity is the part that must not move. A second run issuing a fresh
  harness id would silently orphan everything recorded under the first: the
  server's problems, files and lease are all keyed on it, so the working copy
  would keep working while its history pointed at an id nothing uses.

  Local edits are in the `given_` because that is the realistic second run.
  Settings files accumulate hand edits, and an onboarding that stamps its own
  template over them punishes exactly the engineer who customised their setup.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @settings ".claude/settings.local.json"

  spex "Running onboarding a second time changes nothing" do
    scenario "Onboarding twice is the same as onboarding once" do
      given_ "a working copy already onboarded, since edited by hand", context do
        :ok = Environments.register(context.project.id, context.environment)

        Mix.Task.reenable("cms.harness.onboard")
        first = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, after_first} = Environments.read_file(context.environment, @settings)

        # A realistic hand edit: still valid JSON. An engineer adding their own
        # key is the case this criterion is about. Corrupting the file is a
        # different scenario with a different right answer — see the note below.
        edited =
          after_first
          |> Jason.decode!()
          |> put_in(["env", "EDITOR"], "vim")
          |> Jason.encode!(pretty: true)

        :ok = Environments.write_file(context.environment, @settings, edited)

        {:ok, Map.merge(context, %{first: first, edited: edited})}
      end

      when_ "the engineer runs the onboarding task again", context do
        Mix.Task.reenable("cms.harness.onboard")
        second = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :second, second)}
      end

      then_ "no new identity is issued", context do
        assert context.second.harness_id == context.first.harness_id,
               "the second run issued a different harness id. Problems, files and " <>
                 "the lease are all keyed on it, so everything recorded under the " <>
                 "first id is orphaned while the working copy carries on as though " <>
                 "nothing happened. Got #{inspect(context.second.harness_id)}, was " <>
                 inspect(context.first.harness_id)

        {:ok, context}
      end

      then_ "the settings the engineer edited are left alone", context do
        assert {:ok, after_second} = Environments.read_file(context.environment, @settings)

        assert after_second == context.edited,
               "the second run overwrote settings edited after the first. An " <>
                 "onboarding that stamps its template over local edits cannot safely " <>
                 "be re-run, which means an agent unsure whether a copy is onboarded " <>
                 "has to reason about it instead of asking."

        {:ok, context}
      end
    end
  end
end
