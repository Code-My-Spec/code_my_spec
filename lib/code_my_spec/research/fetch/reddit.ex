defmodule CodeMySpec.Research.Fetch.Reddit do
  @moduledoc """
  Reddit, which cannot be read without credentials, said out loud.

  Omni Tools reads Reddit through the `.json` trick — append `.json` to any
  permalink and get the thread as data. That door is shut. Measured on
  2026-08-28 against a real `/r/elixir` thread, four ways:

      www.reddit.com/…/          200, an 8 KB stub titled "Reddit"
      old.reddit.com/…/          200, a 321 KB login wall
      www.reddit.com/….json      403
      old.reddit.com/….json      200, the same login wall

  And from `curl` with a browser user agent, a 302 to the login page — so it is
  Reddit's policy, not our client. Reading Reddit now needs a registered OAuth
  app.

  ## Why this module still exists

  Deleting it would be worse than keeping it. With no strategy a Reddit URL
  falls through to `Default`, which fetches the login wall, converts it
  happily, and returns it as a page: two hundred words about signing up,
  presented as the thread that was asked for. An agent cannot tell that from an
  answer, and will quote it.

  A refusal naming the reason is the only outcome here that is not a lie. The
  thread-formatting code that would sit on the other side of this is not kept —
  unreachable code cannot be tested — and it is a short job to restore from
  Omni if credentials are ever configured.
  """

  @behaviour CodeMySpec.Research.Fetch.Strategy

  alias CodeMySpec.Research.Fetch.Default

  @hosts ~w(reddit.com www.reddit.com old.reddit.com np.reddit.com)

  @impl true
  def matches?(%URI{host: host}), do: host in @hosts

  @impl true
  def prepare(_url, _uri), do: {:error, :reddit_requires_oauth}

  @impl true
  # Unreachable — `prepare/2` refuses before a request is made — but the
  # behaviour requires it, and delegating is a more honest placeholder than a
  # clause that raises.
  defdelegate extract(response, requested, fetched), to: Default
end
