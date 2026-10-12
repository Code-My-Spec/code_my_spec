defmodule CmsHarness.AppInstance.Runner.LocalMainPortTest do
  @moduledoc """
  9320d5c7 — `main_ports/1` finds main's own HTTP/HTTPS ports by regex-matching
  one exact shape in the checkout's `config/dev.exs`:

      port: String.to_integer(System.get_env("PORT") || "4000")

  Anything else fails to resolve, and the failure is opaque: the caller refuses
  with `:cannot_resolve_main_address`, which reads as "this checkout has no
  address" rather than "I could not read how it declares one". This has already
  cost one real bug (HTTPS required even when an app declared none, fixed in
  1acfb71e1), so the approach is tested here against the ordinary shapes a real
  Phoenix `config/dev.exs` uses.

  Deliberately not solved by reading the listening socket here: that is the
  issue's option (1) and is a deliberate pass of its own. This closes the
  shapes the issue names, so a non-standard-but-ordinary config resolves instead
  of refusing opaquely.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance.Runner.Local

  @q "\""

  defp port_line(env_var, tail) do
    "  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env(" <>
      @q <> env_var <> @q <> ")" <> tail
  end

  # The shape the old regex handled — kept so the fix cannot regress it.
  test "the System.get_env form with a default" do
    content = port_line("PORT", " || " <> @q <> "4000" <> @q <> ")],")

    assert Local.declared_port(content, "PORT") == 4000
  end

  test "the System.get_env form with a different env var name" do
    content = port_line("MY_HTTP_PORT", " || " <> @q <> "8080" <> @q <> ")],")

    assert Local.declared_port(content, "MY_HTTP_PORT") == 8080
  end

  test "a literal integer port" do
    content = "  http: [ip: {127, 0, 0, 1}, port: 4567],"

    assert Local.declared_port(content, "PORT") == 4567
  end

  test "a bare environment read with no default stays unresolvable, and says so here" do
    # `System.get_env("PORT")` with no `|| "4000"`: there is no number in the
    # file to read. This is the honest boundary of reading the checkout — it
    # needs the issue's option (1) (the listening socket, or recording the port
    # at onboarding) and is asserted as a limit rather than papered over with an
    # invented value.
    content = port_line("PORT", ", inet_backend: :inet6],")

    assert Local.declared_port(content, "PORT") == nil,
           "no literal port is readable, so nil — not a guessed number"
  end

  test "an :inet_backend option beside the port does not defeat it" do
    content =
      port_line("PORT", " || " <> @q <> "4000" <> @q <> "), inet_backend: :inet6],")

    assert Local.declared_port(content, "PORT") == 4000
  end

  test "a port declared with no matching env var is nil, not a wrong answer" do
    content = port_line("SOMETHING_ELSE", " || " <> @q <> "9000" <> @q <> ")],")

    assert Local.declared_port(content, "PORT") == nil
  end

  test "a commented-out port, like Phoenix's HTTPS example, is not a declaration" do
    content = """
    config :my_app, MyAppWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4050")]

    #     https: [
    #       port: 4001,
    #       cipher_suite: :strong
    #     ]
    """

    assert Local.declared_port(content, "PORT") == 4050
    assert Local.declared_port(content, "HTTPS_PORT") == nil
  end
end
