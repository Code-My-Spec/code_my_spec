defmodule CmsHarnessTest.Setup do
  @moduledoc """
  Machine setup from a spex: check the prerequisites, read what the last run
  recorded, and whether it passed (stories 1133 and 1140).

  `CodeMySpecSpex` may not reference `CmsHarness`, so the spex calling
  `CmsHarness.Setup` directly compiled forbidden-reference warnings, and a
  compile with warnings fails every copy's compiler gate. Same crossing as
  `CmsHarnessTest.Machine`.
  """

  alias CmsHarness.Setup
  alias CmsHarness.Setup.Platform

  @doc "Run the prerequisite checks, on `opts[:platform]` or this machine's."
  defdelegate check_prerequisites(opts \\ []), to: Setup

  @doc "What the last setup run recorded."
  defdelegate status(), to: Setup

  @doc "Whether a snapshot's prerequisites all passed."
  defdelegate prerequisites_passed?(snapshot), to: Setup

  @doc "The platform this machine is."
  defdelegate platform(), to: Platform, as: :detect
end
