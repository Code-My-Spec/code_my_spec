defmodule CodeMySpec.Hooks.SubagentStopAttributionTest do
  @moduledoc """
  A sub-agent stop must attribute findings the same way a main stop does.

  `SubagentStop.handle/2` called `Validation.validate_stop(scope, task)` — two
  arguments. `validate_stop/3` defaults `opts` to `[]`, and `session_paths/2`
  reads the session id out of `opts`, so it took the "no session id" branch and
  answered `nil`. `nil` renders "Attribution is unavailable for this session, so
  nothing could be demoted and every finding blocks".

  So demotion had never worked on this path for any sub-agent, in any session:
  `log_demotions` lines carry `cms_hook=stop` and never `cms_hook=subagent_stop`.
  Two agents sat blocked for hours on twelve findings in stories neither had
  touched, each with a correct in-project edit recorded against its own agent id.

  The main-stop path was never affected, which is what made this hard to see —
  the same session demoted correctly on `stop` and blocked on `subagent_stop`
  minutes apart.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @session "subagent-stop-attribution-session"

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()

    {1, _rows} =
      Files.upsert_files(scope, [
        %{path: "lib/touched.ex", role: :implementation, fingerprint: "a", valid: true}
      ])

    :ok = FileEdits.track_edit(@session, "lib/touched.ex")

    %{scope: scope}
  end

  # The opts the hook builds are the whole subject here, so they are asserted
  # against the same function the hook feeds rather than a copy of it.
  describe "the opts a sub-agent stop forwards" do
    test "carrying the session id yields a usable attribution set", ctx do
      paths = Validation.session_paths_for_test(ctx.scope, session_id: @session)

      refute is_nil(paths),
             "nil is the bug: it renders as 'attribution unavailable' and blocks everything"

      assert MapSet.member?(paths, "lib/touched.ex")
    end

    # Pins the defaulted-opts shape the hook used to produce. If this ever stops
    # answering nil the bug above stops being detectable by the test beneath it.
    test "dropping them is what produced the blocking answer", ctx do
      assert is_nil(Validation.session_paths_for_test(ctx.scope, []))
    end
  end

  describe "SubagentStop" do
    # Reads the call itself. There is no injection seam on `validate_stop/3`, and
    # the failure is entirely in what the caller passes — a behavioural test would
    # need the full problem/analysis fixture to observe a difference that is
    # already fully determined here.
    test "passes the session id through to validation" do
      source = File.read!("lib/code_my_spec/hooks/subagent_stop.ex")

      assert source =~ ~r/Validation\.validate_stop\(\s*scope,\s*task,/,
             """
             SubagentStop calls validate_stop/2, so opts default to [] and every
             sub-agent stop reports attribution unavailable and blocks on findings
             it did not cause. It must forward session_id and agent_id.
             """

      assert source =~ ~r/session_id:\s*session_id/
      assert source =~ ~r/agent_id:\s*agent_id/
    end
  end
end
