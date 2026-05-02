defmodule CodeMySpecSpex.SpexBoundaryArtifactHelpers do
  @moduledoc """
  Setup helpers for Story 677 — Spex boundary readiness gate.

  Writes the four artifacts that `SpexBoundaryChecker` requires into the
  in-memory environment, with optional `:skip` to omit a specific one
  for failure-path scenarios.

  Path layout matches the rules on Story 677:

    * `mix.exs` — must declare `app: :my_app` so `Helpers.extract_app_name`
      resolves the bridge filename.
    * `.code_my_spec/credo_checks/framework/spex_denied_calls.ex`
    * `.code_my_spec/credo_checks/framework/no_direct_send_in_spex.ex`
    * `test/support/fixtures/my_app_spex_fixtures.ex`
    * `.code_my_spec/knowledge/bdd/spex/index.md`

  Content is intentionally minimal — the checker is existence-only
  (Rule 3), so the bridge file is empty-ish and the BDD plan is a
  one-line markdown header.
  """

  alias CodeMySpec.Environments

  @bridge_relpath "test/support/fixtures/my_app_spex_fixtures.ex"
  @denied_calls_relpath ".code_my_spec/credo_checks/framework/spex_denied_calls.ex"
  @no_send_relpath ".code_my_spec/credo_checks/framework/no_direct_send_in_spex.ex"
  @plan_relpath ".code_my_spec/knowledge/bdd/spex/index.md"

  @doc "Path constants — re-exported so spex assertions can name them without re-deriving."
  def bridge_path, do: @bridge_relpath
  def denied_calls_path, do: @denied_calls_relpath
  def no_send_path, do: @no_send_relpath
  def plan_path, do: @plan_relpath

  @doc """
  Writes the four spex boundary artifacts into the env.

  Pass `skip: [:framework_denied | :framework_send | :bridge | :plan]`
  to omit specific artifacts for failure-path scenarios.
  """
  @spec write_baseline_artifacts(map(), keyword()) :: :ok
  def write_baseline_artifacts(env, opts \\ []) do
    skip = Keyword.get(opts, :skip, [])

    # Don't clobber an existing mix.exs — other fixtures (project setup
    # steps, etc.) may have written a more complete one already. The
    # checker only needs `app:` to resolve, which any reasonable mix.exs
    # will provide.
    unless Environments.file_exists?(env, "mix.exs") == true do
      :ok = Environments.write_file(env, "mix.exs", mix_exs())
    end

    unless :framework_denied in skip do
      :ok = Environments.write_file(env, @denied_calls_relpath, "# Framework: spex denied calls\n")
    end

    unless :framework_send in skip do
      :ok = Environments.write_file(env, @no_send_relpath, "# Framework: no direct send in spex\n")
    end

    unless :bridge in skip do
      :ok = Environments.write_file(env, @bridge_relpath, "defmodule MyAppSpex.Fixtures do\nend\n")
    end

    unless :plan in skip do
      :ok = Environments.write_file(env, @plan_relpath, "# Project BDD spec plan\n")
    end

    :ok
  end

  @doc "Minimal mix.exs that resolves `Helpers.extract_app_name/1` to `\"my_app\"`."
  def mix_exs do
    """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project do
        [app: :my_app]
      end
    end
    """
  end
end
