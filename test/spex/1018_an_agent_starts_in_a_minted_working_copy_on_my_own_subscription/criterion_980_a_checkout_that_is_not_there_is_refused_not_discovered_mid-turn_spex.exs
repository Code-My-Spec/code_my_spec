defmodule CodeMySpecSpex.Story1018.Criterion2887Spex do
  @moduledoc """
  Story 1018 — An agent starts in a minted working copy on my own subscription.
  Criterion 2887 — A checkout that is not there is refused, not discovered
  mid-turn.

  Rule: starting an agent on a checkout that is missing fails at the start, and
  says so.

  ## Where the failure lands is the whole criterion

  An agent started against a path that is not there does not fail immediately in
  any way a person sees. It starts, takes a turn, and dies on its first tool
  call — and what it reports then is a file error. Somebody reading that goes
  looking for the file, finds the whole tree missing, and has to work backwards
  to "the checkout was removed while nothing was watching", which is a
  diagnosis, not a message.

  The refusal is the same clause a restore goes through — criterion 2889 is this
  case arrived at from the other side, bringing an agent back to a copy that
  vanished while its harness was down. Both land on `Engine.start/1` refusing a
  missing working copy, which is what makes this a property of starting rather
  than two special cases that happen to agree.

  ## The second clause is the one that bites

  "And no agent is recorded as running" is not a restatement. A refusal that
  still leaves a process — or a row claiming one — is worse than either
  outcome on its own: the checkout is gone *and* something is pointed at it,
  so every surface reports a healthy agent while nothing it does can work.

  ## Surface

  `Machine.start_agent/3` directly rather than the `start_agent/2` helper, which
  asserts `{:ok, _}` — it exists for criteria whose premise is a running agent,
  and here the refusal is the subject.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]

  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A missing checkout is refused at the start", criterion: 980 do
    scenario "a working copy whose directory has been removed" do
      given_ "a working copy on this machine that has since been removed", context do
        copy = CodeMySpec.TempFile.dir("spex_2887")
        RealDisk.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)

        RealDisk.rm_rf!(copy)

        refute RealDisk.dir?(copy),
               "the premise is a checkout that is gone; with one still there this " <>
                 "asserts nothing about refusing"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "an agent is started on it", context do
        Machine.ensure_supervisor()

        {:ok, Map.put(context, :result, Machine.start_agent(context.agent.id, context.copy))}
      end

      then_ "it refuses and says the checkout is missing", context do
        assert {:error, :working_copy_missing} = context.result,
               """
               An agent was started against a path that is not there.

               It does not fail visibly now — it fails on its first tool call,
               and reports that as a file error. The person reading it goes
               looking for the file, finds the tree gone, and has to work back to
               "the checkout was removed", which is a diagnosis rather than a
               message.

               Got: #{inspect(context.result)}
               """

        {:ok, context}
      end

      then_ "and no agent is recorded as running", context do
        refute running?(context.agent.id),
               """
               The start was refused and something is running for it anyway.

               That is worse than either outcome alone: the checkout is gone and
               a process is pointed at it, so every surface reports a healthy
               agent while nothing it does can work.
               """

        {:ok, context}
      end
    end
  end
end
