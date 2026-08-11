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
  determines whether the sub-agent rules (R5a/R5b), continuous-mode termination
  and task evaluation apply; it is not a precondition for validating.

  These tests hold that invariant by comparing against a resolvable session
  under otherwise identical conditions, rather than by planting a problem: the
  stop pipeline runs the compiler inline in tests, and a clean run reconciles
  the planted row away before the blocking check reads it.

  Short-circuiting on a missing session is the change someone would plausibly
  make to "handle" a malformed payload, and it would turn every hook-payload
  glitch into an unvalidated stop. That is what this file exists to prevent.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias CodeMySpecLocalWeb.Hooks.StopController

  @degenerate [
    {"an empty body", %{}},
    {"no session_id", %{"cwd" => "/tmp/proj"}},
    {"a session_id that resolves to nothing",
     %{"session_id" => "00000000-0000-0000-0000-000000000000"}}
  ]

  setup do
    # Without a cwd, `do_validate_stop/3` returns early on its `%Scope{cwd:
    # nil}` clause, and these tests would pass without reaching the
    # session-resolution path they are about.
    {:ok, tmp} = Briefly.create(directory: true)
    %{scope: %{full_scope_fixture() | cwd: tmp}}
  end

  # `998f4d93` reports the comparison below failing about 1 run in 10, and
  # diagnoses it as a confound: the two calls are sequential, analysis is
  # asynchronous, and a run landing between them makes the second decide with
  # problems the first did not have.
  #
  # It does not reproduce. 61 consecutive runs of the issue's own command —
  # `--repeat-until-failure 30 --seed 7`, twice — zero failures.
  #
  # The mechanism that would explain both the report and the silence is
  # `analysis_mode: :inline`, which `config/test.exs` has set since 469530bb
  # (2026-07-09, before the report). Inline runs execute in the calling process,
  # so each `post_stop` finishes its analysis before returning and there is no
  # window between the calls to lose. Whatever the reporter hit, it was not
  # simply "async run lands mid-test" in this configuration.
  #
  # The confound is still real as *design* — the variable this claims to isolate
  # does sit on top of call order — so if it returns, fix the shape rather than
  # re-diagnosing it. What the report also noticed and is worth more attention:
  # the 28 problems it saw were the real project's compiler warnings, absolute
  # paths under the worktree, against a fixture whose cwd is a temp dir. A
  # correctly isolated test cannot see those at all, and that part has no
  # explanation yet.
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
