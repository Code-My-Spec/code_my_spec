defmodule CodeMySpec.Environments.HarnessTest do
  @moduledoc """
  A working copy on another machine, addressed over its harness channel.

  The server holds no checkout, so `scope.environment` was `nil` there and every
  file operation answered `{:error, :no_environment}` — "there is no working
  copy", which is false. There is one; it is elsewhere. Forty-eight server-side
  modules acted on that answer, nineteen of them agent tasks whose evaluators run
  on the server, and each failure was reported as its own bug: a spec that could
  not be read and was pruned, an evaluator that could not read its artifact and
  took the stop gate down, a tool that could not write a stub and said the server
  had no working copy.

  These cover the half that can be wrong without anything crashing: the error
  the caller gets when the harness is not there, and the shape a result comes
  back in. The far side is deliberately dumb — it applies the op with the same
  `Environments` API against its own disk — so it is not mocked here.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  defp env(ref \\ %{"harness_id" => Ecto.UUID.generate()}) do
    %Environment{type: :harness, cwd: "/somewhere/else", ref: ref}
  end

  # Every unreachable-family refusal is `{:error, {tag, details}}`. It used to
  # be the bare atom `:harness_unreachable` for all of them, which reached the
  # agent naming no working copy, no operation and no elapsed time — and read
  # as "no harness" even when the harness was registered and answering.
  defp unreachable?({:error, {tag, details}}) when is_map(details) do
    tag in [
      :harness_not_registered,
      :harness_timeout,
      :harness_self_call,
      :harness_registry_down,
      :harness_not_configured,
      :harness_no_id
    ]
  end

  defp unreachable?(_), do: false

  describe "when no harness is serving the working copy" do
    test "reads report unreachable, not absent" do
      result = Environments.read_file(env(), "lib/thing.ex")

      assert unreachable?(result)
      assert {:error, {:harness_not_registered, %{op: "read_file"}}} = result
    end

    test "writes report unreachable rather than silently succeeding" do
      assert unreachable?(Environments.write_file(env(), "spec.md", "content")),
             "a write that cannot reach the disk must not answer :ok — a spec stub " <>
               "reported as written and absent is worse than a refusal"
    end

    test "the error is distinct from :no_environment" do
      # The whole point. `:no_environment` means there is no working copy, and
      # callers prune and report absence on it. This means there is one and it
      # cannot be reached right now, which must not prune anything.
      assert unreachable?(Environments.list_directory(env(), "."))
      refute match?({:error, :no_environment}, Environments.list_directory(env(), "."))
    end

    test "the refusal names the operation and the working copy" do
      # The old atom arrived bare. Whoever read it had to go and find out which
      # of forty operations on which of five working copies it was about.
      id = Ecto.UUID.generate()

      assert {:error, {_tag, details}} =
               Environments.read_file(env(%{"harness_id" => id}), "lib/thing.ex")

      assert details.harness_id == id
      assert details.op == "read_file"
    end

    test "existence answers false rather than raising" do
      refute Environments.file_exists?(env(), "anything")
    end

    test "glob answers an empty list rather than raising" do
      assert Environments.glob(env(), "**/*.ex") == []
    end
  end

  describe "an environment with no harness id" do
    test "is unreachable rather than crashing" do
      # A `:harness` environment built without a ref is a construction bug, and
      # it should surface as a refusal rather than a MatchError deep in a call
      # stack that says nothing about where it came from. It gets its own tag
      # because the fix is here rather than on any harness — nothing is
      # unreachable, the environment was built wrong.
      assert {:error, {:harness_no_id, details}} =
               Environments.read_file(env(%{}), "lib/thing.ex")

      assert details.op == "read_file"
      assert details.ref == %{}
    end
  end

  describe "operations that do not belong here" do
    test "cmd is refused, because analysis/run owns running commands" do
      assert {:error, :not_supported_on_harness} =
               Environments.cmd(env(), "mix", ["test"], [])
    end
  end
end
