defmodule CodeMySpec.BddSpecs.ContentCheckTest do
  @moduledoc """
  The checks that decide whether a spex file is usable, separated from the
  reading of it.

  That separation is the fix for a real defect: while these lived behind an
  `Environment`, a server with no working copy answered "Spec file not found"
  for six specs that were on the agent's disk — in a stop no edit could clear,
  while the requirement graph read the harness's file report in the same second
  and correctly reported them present.

  So the properties worth asserting here are that the checks are pure (no disk,
  anywhere) and that `describe/2` never turns "I did not look" into "it is not
  there".
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.ContentCheck

  defp spec(body) do
    """
    defmodule DemoSpex.ExampleSpex do
      use DemoSpex.Case

    #{body}
    end
    """
  end

  @scenario """
    spex "publishing" do
      scenario "one command", %{} do
        given_ "a repo", %{} = context do
          {:ok, context}
        end

        when_ "publish runs", %{} = context do
          {:ok, context}
        end

        then_ "the post is live", %{} = context do
          {:ok, context}
        end
      end
    end
  """

  describe "check/2" do
    test "a well-formed spec passes" do
      assert :ok = ContentCheck.check(spec(@scenario), "a_spex.exs")
    end

    test "a file that does not parse is a syntax error, located" do
      assert {:error, {:syntax_error, %{message: message}}} =
               ContentCheck.check("defmodule Broken do\n  def x( \nend\n", "broken_spex.exs")

      assert is_binary(message)
    end

    # The macros only resolve through the project's case template, so a spec
    # without it cannot run at all — and would otherwise fail much later with a
    # message about an undefined macro rather than about the missing `use`.
    test "a spec that does not use the Spex case is refused" do
      content = """
      defmodule DemoSpex.ExampleSpex do
        use DemoWeb.ConnCase

      #{@scenario}
      end
      """

      assert {:error, :missing_spex_case} = ContentCheck.check(content, "a_spex.exs")
    end

    test "a spex block with no scenarios in it is refused" do
      assert {:error, :no_scenarios} =
               ContentCheck.check(spec("  spex \"publishing\" do\n  end\n"), "a_spex.exs")
    end

    # Ordered before the scenario check, so a file with no `spex` macro at all
    # is reported as unparseable rather than as an empty spec. Both are refusals;
    # only one of them describes what is actually wrong.
    test "a file with no spex macro is a parse error, not an empty spec" do
      assert {:error, {:parse_error, :no_spex_macro}} = ContentCheck.check(spec(""), "a_spex.exs")
    end

    # Pure by construction: a path that exists nowhere must not change the
    # answer, because nothing here is allowed to go and look.
    test "the path is a label, not something read" do
      assert :ok =
               ContentCheck.check(spec(@scenario), "/nonexistent/definitely/not/here_spex.exs")
    end
  end

  describe "describe/2" do
    test "absence and not-having-looked are different sentences" do
      absent = ContentCheck.describe(:file_not_found, "a_spex.exs")
      unread = ContentCheck.describe(:no_environment, "a_spex.exs")
      unjudged = ContentCheck.describe(:no_verdict, "a_spex.exs")

      assert absent == "Spec file not found"

      refute unread =~ "not found",
             "this is what an agent cannot act on: the file it is told to write is already there"

      assert unread =~ "not a claim that the file is missing"

      refute unjudged =~ "not found"
      assert unjudged =~ "exists"
    end

    test "an unrecognised reason still says something" do
      assert ContentCheck.describe({:weird, :thing}, "a_spex.exs") =~ "weird"
    end
  end
end
