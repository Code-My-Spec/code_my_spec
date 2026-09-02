defmodule CmsHarness.Mcp.Transport do
  @moduledoc """
  The wire, behind a seam — the same shape `CmsHarness.Project.Transport` uses
  for the channel, and for the same reason.

  There, outbound was three operations and everything inbound was already an
  ordinary function a test could call. Here it is two: call a tool, and ask what
  tools there are. Everything worth testing sits on either side of them — the
  tool wrapper, the truncation, the catalog, the scoping, and the Lua — and none
  of it could be reached without a listening socket, because
  `CodeMySpecWeb.Endpoint` runs `server: false` in test.

  What is deliberately not abstracted, again: the answers. The local transport
  dispatches to the real server-side tool and returns what it really said. A
  recorder would make every criterion here a check on a fixture somebody wrote
  by hand, which is the failure the story is about — an agent reasoning about a
  catalogue instead of about the project.
  """

  @type client :: term()

  @doc "Open a session. `opts` carries `:base_url`, `:mcp_path` and `:headers`."
  @callback connect(name :: term(), opts :: keyword()) :: {:ok, client()} | {:error, term()}

  @doc "Call one tool and hand back its text."
  @callback call(client(), tool :: String.t(), arguments :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  The same, with the caller's deadline.

  `opts` carries `:timeout` in milliseconds. Separate from `call/3` rather than
  replacing it because most callers have no opinion and the client's own
  default is the right one for them; a browser call is the exception, and it is
  the whole reason this arity exists.
  """
  @callback call(client(), tool :: String.t(), arguments :: map(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "The names a server offers, without their schemas."
  @callback list_tool_names(client()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  The configured transport.

  Defaults to the real one; tests set `:harness_mcp_transport`. Read at call
  time rather than compiled in, so a test can swap it per-case.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :harness_mcp_transport, __MODULE__.Anubis)
end
