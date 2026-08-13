defmodule CodeMySpecSpex.Story1013.Criterion2370Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2370 — A consumer resolves the recorded partition, not one it derives.

  Rule: The test partition is assigned once at onboarding and read from
  configuration thereafter, never derived.

  The rule the rest of this story was written to serve, and the one nothing
  tested. Every other criterion checks the *producer* against itself — that the
  report matches the settings file, that the printed name matches the printed
  command. All true, and all of it would still pass if no consumer read a word of
  it.

  It did. `TestDatabase.partition_for/1` digested the cwd and
  `Onboarding.partition_name/1` digested it identically, in two repositories, and
  the analyzer set `MIX_TEST_PARTITION` from its own copy. They agreed because two
  implementations of one algorithm agreed — a coincidence maintained by hand, and
  a stricter form of the defect this story exists to remove. Recording a value
  nobody reads replaced two derivations with three.

  ## Why the recorded value is deliberately unreachable by digest

  `given_` records a partition no `sha256` could produce. That is the whole
  design: a spec that records a *plausible* partition passes whether the consumer
  reads it or recomputes it, because both answers are the same string. This one
  can only pass by reading.
  """

  use CodeMySpecSpex.Case

  alias ClientUtils.Harness.Onboarding
  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @settings ".claude/settings.local.json"

  # Not a hex digest: digests are 8 lowercase hex characters after an `h`. Nothing
  # that derives a partition can return this, so reading is the only way to get it.
  @recorded "recorded-not-derived"

  spex "The recorded partition is the one consumers use" do
    scenario "A consumer resolves the recorded partition, not one it derives" do
      given_ "a working copy whose recorded partition no digest would produce", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            @settings,
            Jason.encode!(%{"env" => %{"MIX_TEST_PARTITION" => @recorded}}, pretty: true)
          )

        {:ok, context}
      end

      when_ "a consumer resolves this copy's test partition", context do
        env = context.environment

        resolved =
          Onboarding.resolve_partition(env.cwd, read: &Environments.read_file(env, &1))

        resolved = with {:ok, partition} <- resolved, do: partition

        {:ok, Map.put(context, :resolved, resolved)}
      end

      then_ "it is the recorded value", context do
        assert context.resolved == @recorded,
               "the consumer did not read the recorded partition. It returned " <>
                 "#{inspect(context.resolved)}, which is what deriving from the path " <>
                 "produces — so the value onboarding wrote is decoration and every " <>
                 "consumer is still computing its own. Two derivations agreeing by " <>
                 "coincidence is what this story replaces; a third one that also " <>
                 "agrees is not progress."

        {:ok, context}
      end

      then_ "it is not the value a digest would have produced", context do
        refute context.resolved == Onboarding.partition_name(context.environment.cwd),
               "the consumer returned the derived partition. With a recorded value " <>
                 "present, deriving means the recording is never consulted — and the " <>
                 "two only ever match because the algorithm is duplicated by hand."

        {:ok, context}
      end

      then_ "a copy with nothing recorded is refused rather than given one", context do
        {:ok, bare} = Briefly.create(directory: true)

        assert {:error, :not_onboarded} = Onboarding.resolve_partition(bare),
               "an un-onboarded copy was handed a partition anyway. A derive-on-miss " <>
                 "fallback keeps both mechanisms alive for exactly the copies nobody " <>
                 "onboarded, silently — which is how the first pair survived. One " <>
                 "path means the answer is read or it is refused."

        {:ok, context}
      end
    end
  end

  # `read:` closes over the environment, so the spec drives the resolver against the
  # same in-memory copy onboarding writes to rather than a filesystem it arranged.
end
