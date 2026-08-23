defmodule CmsHarness.WorkingCopies do
  @moduledoc """
  Which working copy a harness id names.

  A hook arrives addressed to an id. The answer comes from the working copy's
  own config — `CmsHarness.HarnessConfig`, minted at onboarding — which says
  both which harness it is and where it is.

  ## Two sources, both authoritative, neither a guess

  The copies this harness already knows about answer first: the one it was
  started in, and any it is serving. Their configs are on disk, so this needs
  no network and answers before anything is connected — which is the sprite,
  and every hook after a copy's first.

  Anything else is the server's to answer, from the harness object, which
  records the same root the copy reported. That is what lets one harness serve
  several copies without being configured with a list of them.

  What is *not* here is discovery. This used to walk up from the directory a
  hook fired in, and later read a list of directories out of the environment.
  The walk resolved one session differently depending on which subdirectory it
  fired from and resolved a nested checkout to the outer one; the list put the
  operator back in the business of registering paths, and made the laptop a
  different shape from the sprite. A hook naming an id nothing can account for
  is refused, not resolved to something nearby.
  """

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Projects
  alias CmsHarness.Token

  @doc """
  The directory this id names.

  Copies already being served answer first — that is every hook after the
  first. Otherwise the harness's own working copy is consulted, which is what
  answers the first one.

  Three answers, not two. `:unknown` means the server was asked and did not
  recognise the id — re-onboarding fixes that. `{:unreachable, reason}` means
  the server could not be asked at all, and re-onboarding fixes nothing.
  """
  @spec root(String.t()) :: {:ok, String.t()} | :unknown | {:unreachable, term()}
  def root(working_copy_id) when is_binary(working_copy_id) and working_copy_id != "" do
    case Enum.find(known(), fn {id, _root} -> id == working_copy_id end) do
      {_id, root} -> {:ok, root}
      nil -> ask_server(working_copy_id)
    end
  end

  def root(_), do: :unknown

  # The harness object holds the root each copy reported when it joined. Asking
  # for it is how one harness serves a copy it was not started in, without
  # anybody maintaining a list of directories.
  defp ask_server(working_copy_id) do
    with {:ok, token} <- Token.access_token(),
         {:ok, %{status: 200, body: %{"root" => root}}} when is_binary(root) and root != "" <-
           get(working_copy_id, token) do
      {:ok, root}
    else
      {:ok, %{status: 404}} ->
        Logger.warning("[CmsHarness] the server does not know harness #{working_copy_id}")
        :unknown

      # Not `:unknown`. "The server said no" and "I could not ask the server"
      # have different fixes, and collapsing them sent the refusal's reader to
      # re-run `mix cms.harness.onboard` on a correct id, which rewrites a
      # working config and still does not work.
      #
      # Measured: `:4000` was down, `Token.access_token/0` answered
      # `econnrefused`, and the hook came back "the hooks are addressed to a
      # harness id the server does not recognise". The right line was already in
      # harness.log directly above it.
      other ->
        Logger.warning(
          "[CmsHarness] could not ask where harness #{working_copy_id} is: #{inspect(other)}"
        )

        {:unreachable, other}
    end
  end

  defp get(working_copy_id, token) do
    Req.get(
      url:
        Config.server_url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/api/harnesses/#{working_copy_id}"),
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      receive_timeout: to_timeout(second: 10)
    )
  end

  @doc """
  Every working copy this harness can answer for, as `id => root`.

  The copies it is serving, plus the one it was started in — which is the same
  set once the first hook has arrived, and differs only before it.
  """
  @spec all() :: %{String.t() => String.t()}
  def all, do: Map.new(known())

  defp known do
    [File.cwd!() | Projects.list()]
    |> Enum.uniq()
    |> Enum.flat_map(&entry/1)
  end

  defp entry(root) do
    # `read_file/1`, not `read/1`: this enumerates every working copy the
    # harness knows about, and `read/1` honors `CMS_HARNESS_ID` — set in the
    # environment of every worktree session on this machine — which would
    # answer every root here with the same id and collapse this map down to
    # whichever root got processed last.
    case HarnessConfig.read_file(root) do
      {:ok, %{working_copy_id: id, root: configured}} -> [{id, configured || root}]
      _ -> []
    end
  end
end
