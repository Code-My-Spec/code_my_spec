defmodule CmsHarness.Web.InitController do
  @moduledoc """
  `POST /api/skills/init` — what `/codemyspec:init` posts to.

  The one onboarding step a packaged install can take: a checkout needs only
  `.cms_harness.json`. MCP resolves the copy from `?dir=` and hooks from `cwd`,
  both by walking to that file, so no env block or settings are written.

  The route lived on `CodeMySpecLocalWeb` and was deleted with it (87bc97213),
  leaving the skill posting to a 404 and `mix cms.harness.onboard` as the only
  way to mint — unavailable to anyone without a checkout of this repo.

  Answers 200 with `prompt` in every case, for the reason `SkillsController`
  does: the body is piped into the agent's context and is all it will see.
  """

  use Phoenix.Controller, formats: [:json]

  alias CmsHarness.Authorization
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Onboarding

  def start(conn, params) do
    mint = fn root -> Onboarding.mint(root, project_argument(params["arguments"])) end
    prompt = respond(conn.assigns.working_copy, Authorization.status(), mint)
    conn |> put_status(200) |> json(%{prompt: prompt})
  end

  # `/codemyspec:init <project_id>`: the tracked config.yml names the project on
  # one server only, so a clone joining another server's project says which.
  defp project_argument(arguments) when is_binary(arguments) do
    case String.split(arguments) do
      [id | _] -> id
      [] -> nil
    end
  end

  defp project_argument(_), do: nil

  @doc """
  The answer for a resolution and an authorization status. Public so each
  branch is testable without a server; `mint` (given the root) runs only once
  signed in.
  """
  def respond({:ok, root}, _status, _mint) do
    "#{root} is already onboarded as harness #{harness_id(root)}. Run /codemyspec:next to start work."
  end

  def respond({:not_onboarded, dir}, %{phase: :pending} = status, _mint) do
    """
    This harness is not signed in to #{CmsHarness.Config.server_url()} yet. Ask the user to \
    open #{status.verification_uri} and enter the code #{status.user_code}, then run \
    /codemyspec:init again.
    """ <> "Nothing has been written to #{dir}."
  end

  def respond({:not_onboarded, dir}, %{phase: :authorized}, mint) do
    case mint.(dir) do
      {:ok, id} ->
        "Onboarded #{dir} as harness #{id}. Run /codemyspec:next to start work."

      {:error, message} ->
        "Onboarding #{dir} failed: #{String.trim(message)}\n\nIf this checkout belongs to a " <>
          "different project on #{CmsHarness.Config.server_url()} than its .code_my_spec/config.yml " <>
          "names, run /codemyspec:init <project_id> with that project's id."
    end
  end

  def respond({:not_onboarded, dir}, status, _mint) do
    "This harness cannot onboard #{dir} until it is signed in (authorization #{status.phase}). " <>
      "Check that the CodeMySpec service is running (`cms start`), then run /codemyspec:init again."
  end

  def respond(reason, _status, _mint) do
    "/codemyspec:init runs from a project directory (one with .code_my_spec/config.yml): " <>
      CmsHarness.HookDecision.summarize(reason)
  end

  defp harness_id(root) do
    case HarnessConfig.read(root) do
      {:ok, %{working_copy_id: id}} -> id
      _ -> "(unreadable)"
    end
  end
end
