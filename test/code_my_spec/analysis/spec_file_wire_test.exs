defmodule CodeMySpec.Analysis.SpecFileWireTest do
  @moduledoc """
  The seam between the spex fork and this repo, end to end.

  `cd2a0db4`: a failure raised in a LiveView process carries no `_spex.exs`
  stack frame and an `error.file` that is library code, so nothing can name the
  spec it belongs to. The fix spans two repos — the formatter emits `spec_file`,
  this side reads it — and the halves land separately.

  Unit tests on `Runners.spex_location/2` prove the *rule*. They cannot prove
  the *wiring*: that a `spec_file` written by the fork survives JSONL parsing,
  reaches the `Failure` struct, gets relativized, crosses `spex_failure/1` onto
  the wire, and comes back out of `from_raw/2` as a Problem filed against the
  spec. Four hand-offs, each of which could drop the field silently — and
  dropping it looks exactly like the fork not having landed yet.

  So this walks the whole chain against a line shaped the way the fork will
  write it. It passes today with the field absent, and starts asserting the
  attribution the moment the fork emits it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners
  alias CodeMySpec.BddSpecs.Spex

  @root "/Users/dev/project"
  @spec_rel "test/spex/969_sending_mail/criterion_8024_the_domain_is_known_spex.exs"

  # The shape the fork writes: a raise from a LiveView process, so every frame
  # is library code and `error.file` is the raise site rather than the spec.
  defp jsonl_line(extra) do
    Map.merge(
      %{
        "type" => "failure",
        "spex" => "Sam's domain is known to the mail provider",
        "scenario" => "the email step registers the domain with the provider",
        "steps" => [],
        "error" => %{
          "message" => "cannot find mock/stub CodeMySpec.Provisioning.Resend in process",
          "file" => "lib/req/test.ex",
          "line" => 494,
          "stacktrace" => [
            %{"file" => "lib/req/test.ex", "line" => 494, "module" => "Req.Test"},
            %{"file" => "lib/req/plug.ex", "line" => 207, "module" => "Req.Plug"}
          ]
        }
      },
      extra
    )
    |> Jason.encode!()
  end

  defp parse(line, tmp_dir) do
    path = Path.join(tmp_dir, "failures.jsonl")
    File.write!(path, line <> "\n")
    {:ok, [failure]} = Spex.parse_jsonl(path)
    failure
  end

  # The whole chain: parse -> relativize -> onto the wire -> back into a Problem.
  defp problem_for(failure) do
    diagnostic =
      failure
      |> Spex.relativize_error_file(@root)
      |> CmsHarness.Analysis.spex_failure()

    {:ok, result} = Runners.from_raw("spex", %{"exit_status" => 1, "diagnostics" => [diagnostic]})
    [problem] = result.problems
    problem
  end

  @tag :tmp_dir
  test "a spec_file the fork writes reaches the Problem", %{tmp_dir: tmp_dir} do
    failure = parse(jsonl_line(%{"spec_file" => "#{@root}/#{@spec_rel}"}), tmp_dir)

    assert failure.spec_file == "#{@root}/#{@spec_rel}",
           "the parser dropped the field before anything else could use it"

    problem = problem_for(failure)

    assert problem.file_path == @spec_rel,
           "the failure named its spec and the Problem should be filed there, relative " <>
             "to the working copy — an absolute path is deleted by the next file sync"

    refute problem.line,
           "the spec is known, where in it is not; a line from the raising file would be worse"
  end

  # Until the fork lands, every line looks like this. It must behave exactly as
  # it does today — that is what makes reader-before-writer safe.
  #
  # `nil` rather than "unknown": this chain stops at `from_raw/2`, and it is
  # `Reconciler.patch_file_path/1` that turns a nil into "unknown" later, so the
  # Problem schema's not-null holds. Asserting "unknown" here would be asserting
  # against the wrong stage — which is how the first version of this test failed.
  @tag :tmp_dir
  test "without spec_file it names no file, as today", %{tmp_dir: tmp_dir} do
    problem = jsonl_line(%{}) |> parse(tmp_dir) |> problem_for()

    refute problem.file_path
  end

  # The guard that stopped failures being filed against `req_cassette/plug.ex`
  # has to survive the new field: a `spec_file` that is not a spec is refused
  # rather than trusted.
  @tag :tmp_dir
  test "a spec_file that is not a spec is refused", %{tmp_dir: tmp_dir} do
    problem =
      %{"spec_file" => "#{@root}/lib/code_my_spec/mail.ex"}
      |> jsonl_line()
      |> parse(tmp_dir)
      |> problem_for()

    refute problem.file_path
  end
end
