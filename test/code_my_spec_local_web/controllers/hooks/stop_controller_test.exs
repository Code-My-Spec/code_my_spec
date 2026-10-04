defmodule CodeMySpecLocalWeb.Hooks.StopControllerTest do
  @moduledoc """
  Degenerate stop-hook payloads.

  Issue 919742ba reported that the hook answers `200 OK` with `{}` for an empty
  body, a missing `session_id`, and an unknown `session_id`. It does — but `{}`
  is the hook protocol's "allow", and an allow is the right answer when the
  validators found nothing to say. The question the report leaves open is
  whether validation *ran*, or whether an unresolvable session skipped it.

  It runs. `decide/7` has a `session == nil` clause, and that clause calls
  `run_and_decide/6` — the same path a resolved session takes. The session only
  determines whether the sub-agent rule (R5a), continuous-mode termination
  and task evaluation apply; it is not a precondition for validating.

  These tests hold that invariant by comparing against a resolvable session
  under otherwise identical conditions, rather than by planting a problem: a
  clean analyzer result reconciles a planted row away before the blocking check
  reads it.

  "Otherwise identical" holds because a stop never starts analysis (John,
  2026-10-04): nothing runs between the two calls, so the two sides differ in
  exactly one thing.

  Short-circuiting on a missing session is the change someone would plausibly
  make to "handle" a malformed payload, and it would turn every hook-payload
  glitch into an unvalidated stop. That is what this file exists to prevent.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{SessionsFixtures, UsersFixtures}
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Environments.Environment
  alias CodeMySpecLocalWeb.Hooks.StopController

  @degenerate [
    {"an empty body", %{}},
    {"no session_id", %{"cwd" => "/tmp/proj"}},
    {"a session_id that resolves to nothing",
     %{"session_id" => "00000000-0000-0000-0000-000000000000"}}
  ]

  setup do
    # A directory, because `do_validate_stop/3` returns early on its
    # `%Scope{cwd: nil}` clause and these tests would then pass without reaching
    # the session-resolution path they are about. A stop compiles nothing, so
    # it can stay empty.
    {:ok, tmp} = Briefly.create(directory: true)

    # `cwd` **and** `environment`, pointed at the same directory.
    #
    # They were two different ones, and it mattered. `full_scope_fixture/1`
    # anchors `environment` at a Briefly dir of its own; this setup used to
    # write a Mix project into a second one and assign it to `cwd`.
    # `Runners.run("compiler", scope, …)` reads `scope.environment`, so the
    # project was written where nothing compiled it and every call answered
    #
    #     ** (Mix) Could not find a Mix.Project
    #
    # which `[Compile]` records as "treating as transient". The comment on that
    # Mix project said it existed to eliminate exactly that outcome, and it had
    # never done so: six of those warnings per run, one per `post_stop`, right
    # up until this line. The fix was in the file and pointed at the wrong
    # directory, which is the same shape as the bug it was fixing.
    #
    # Kept aligned rather than deleted, because a scope whose two notions of
    # "where this working copy is" disagree is not a thing to leave lying in a
    # fixture — the next analyzer to read one instead of the other finds the
    # same trap.
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    %{scope: scope}
  end

  # `998f4d93` reports the comparison below failing about 1 run in 10, and
  # diagnoses it as a confound: the two calls are sequential, analysis is
  # asynchronous, and a run landing between them makes the second decide with
  # problems the first did not have.
  #
  # The confound is real as *design* — the variable this isolates does sit on
  # top of call order — but the thing that could vary underneath it is gone.
  # A stop starts no run, so there is no run to land, no ledger state to differ,
  # and nothing for the order to confound with.
  #
  # It stopped reproducing before that: 61 consecutive runs of the issue's own
  # command, `--repeat-until-failure 30 --seed 7` twice, zero failures. The
  # mechanism that explains the silence is `analysis_mode: :inline`
  # (`config/test.exs`, since 469530bb, before the report) — inline runs execute
  # in the calling process, so each `post_stop` finished its analysis before
  # returning and there was no window to lose.
  #
  # What the report also noticed is the part worth keeping: the 28 problems it
  # saw were the *real project's* compiler warnings, absolute paths under the
  # worktree, against a fixture rooted in a temp dir. This file did have a
  # directory bug of exactly that shape — `cwd` and `environment` pointed at two
  # different Briefly dirs, so the Mix project written to prevent a transient
  # compile outcome was written where nothing compiled it, and all six calls hit
  # the transient branch anyway. Fixed in the setup above. Whether it is *the*
  # explanation is unproven: it accounts for an unstable analyzer outcome, not
  # for absolute paths under the worktree appearing at all.
  describe "payloads that name no resolvable session" do
    for {label, params} <- @degenerate do
      test "#{label} decides the same as a resolvable session", %{scope: scope} do
        session =
          session_fixture(scope, %{
            external_conversation_id: "resolvable-#{System.unique_integer([:positive])}"
          })

        degenerate = post_stop(scope, unquote(Macro.escape(params)))
        resolvable = post_stop(scope, %{"session_id" => session.external_conversation_id})

        assert degenerate == resolvable,
               "an unresolvable session took a different path than a resolvable one, " <>
                 "which is how a skipped validation would show up"
      end
    end

    test "the response is a decision map, never a non-map", %{scope: scope} do
      for {_label, params} <- @degenerate do
        assert is_map(post_stop(scope, params))
      end
    end
  end

  describe "visibility when the session cannot be resolved" do
    test "a payload with no session_id warns", %{scope: scope} do
      log = capture_log(fn -> post_stop(scope, %{"cwd" => "/tmp/proj"}) end)

      assert log =~ "no session_id in payload",
             """
             Allow is the right verdict, but a hook that never sends session_id
             answers 200 forever and is indistinguishable from a healthy run.
             An unattended drill is exactly where nobody is watching the 200s
             go by.
             """
    end

    test "a session_id with no record warns and names the recovery", %{scope: scope} do
      log =
        capture_log(fn ->
          post_stop(scope, %{"session_id" => "00000000-0000-0000-0000-000000000000"})
        end)

      assert log =~ "has no session record"

      assert log =~ "/mcp",
             "this is the stale-MCP-connection failure; the log should say how to recover"
    end

    test "a resolvable session says nothing", %{scope: scope} do
      session =
        session_fixture(scope, %{
          external_conversation_id: "quiet-#{System.unique_integer([:positive])}"
        })

      log =
        capture_log(fn ->
          post_stop(scope, %{"session_id" => session.external_conversation_id})
        end)

      refute log =~ "#{session.external_conversation_id} has no session record",
             "a warning on the healthy path is noise, and noise is why nobody " <>
               "reads the ones that matter"
    end

    test "a stop before init_project stays quiet", %{scope: scope} do
      unbound = %{scope | active_project_id: nil, active_project: nil}

      log = capture_log(fn -> post_stop(unbound, %{}) end)

      refute log =~ "no session_id in payload",
             "there is no project to hold sessions yet — that is a normal " <>
               "bootstrap state, not broken configuration"
    end
  end

  defp post_stop(scope, params) do
    conn(:post, "/api/hooks/stop", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, params)
    |> StopController.handle(params)
    |> then(fn conn ->
      assert conn.status == 200
      Jason.decode!(conn.resp_body)
    end)
  end
end
