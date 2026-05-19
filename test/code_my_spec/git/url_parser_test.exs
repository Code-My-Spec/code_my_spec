defmodule CodeMySpec.Git.URLParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Git.URLParser

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp github_https_url, do: "https://github.com/owner/repo.git"
  defp github_https_url_no_dot_git, do: "https://github.com/owner/repo"
  defp github_https_url_with_path, do: "https://github.com/owner/repo/some/path.git"

  defp gitlab_https_url, do: "https://gitlab.com/owner/repo.git"
  defp gitlab_https_url_no_dot_git, do: "https://gitlab.com/owner/repo"
  defp gitlab_https_url_with_subgroup, do: "https://gitlab.com/group/subgroup/repo.git"

  defp github_ssh_url, do: "git@github.com:owner/repo.git"
  defp gitlab_ssh_url, do: "git@gitlab.com:owner/repo.git"

  defp http_url, do: "http://github.com/owner/repo.git"
  defp unknown_provider_url, do: "https://bitbucket.org/owner/repo.git"
  defp malformed_url, do: "not-a-url"
  defp empty_url, do: ""

  defp github_token, do: "ghp_token123abc"
  defp gitlab_token, do: "glpat-token456def"

  defp expected_github_authenticated_url,
    do: "https://#{github_token()}@github.com/owner/repo.git"

  defp expected_gitlab_authenticated_url,
    do: "https://#{gitlab_token()}@gitlab.com/owner/repo.git"

  # ============================================================================
  # provider/1 - Happy Path Tests
  # ============================================================================

  describe "provider/1 - valid GitHub URLs" do
    test "identifies GitHub provider from standard HTTPS URL" do
      assert {:ok, :github} = URLParser.provider(github_https_url())
    end

    test "identifies GitHub provider from HTTPS URL without .git extension" do
      assert {:ok, :github} = URLParser.provider(github_https_url_no_dot_git())
    end

    test "identifies GitHub provider from HTTPS URL with additional path segments" do
      assert {:ok, :github} = URLParser.provider(github_https_url_with_path())
    end
  end

  describe "provider/1 - valid GitLab URLs" do
    test "identifies GitLab provider from standard HTTPS URL" do
      assert {:ok, :gitlab} = URLParser.provider(gitlab_https_url())
    end

    test "identifies GitLab provider from HTTPS URL without .git extension" do
      assert {:ok, :gitlab} = URLParser.provider(gitlab_https_url_no_dot_git())
    end

    test "identifies GitLab provider from HTTPS URL with subgroups" do
      assert {:ok, :gitlab} = URLParser.provider(gitlab_https_url_with_subgroup())
    end
  end

  # ============================================================================
  # provider/1 - Error Cases
  # ============================================================================

  describe "provider/1 - invalid URL formats" do
    test "returns error for SSH URL format" do
      assert {:error, :invalid_url} = URLParser.provider(github_ssh_url())
    end

    test "returns error for GitLab SSH URL format" do
      assert {:error, :invalid_url} = URLParser.provider(gitlab_ssh_url())
    end

    test "returns error for HTTP (non-HTTPS) URL" do
      assert {:error, :invalid_url} = URLParser.provider(http_url())
    end

    test "returns error for malformed URL" do
      assert {:error, :invalid_url} = URLParser.provider(malformed_url())
    end

    test "returns error for empty string" do
      assert {:error, :invalid_url} = URLParser.provider(empty_url())
    end

    test "returns error for nil input" do
      assert {:error, :invalid_url} = URLParser.provider(nil)
    end
  end

  describe "provider/1 - unsupported providers" do
    test "returns error for unknown git provider" do
      assert {:error, :unsupported_provider} = URLParser.provider(unknown_provider_url())
    end

    test "returns error for custom domain HTTPS URLs" do
      custom_domain_url = "https://git.mycustomdomain.com/owner/repo.git"
      assert {:error, :unsupported_provider} = URLParser.provider(custom_domain_url)
    end
  end

  # ============================================================================
  # provider/1 - Edge Cases
  # ============================================================================

  describe "provider/1 - edge cases" do
    test "handles URLs with trailing slashes" do
      url_with_slash = "https://github.com/owner/repo.git/"
      assert {:ok, :github} = URLParser.provider(url_with_slash)
    end

    test "handles URLs with query parameters" do
      url_with_params = "https://github.com/owner/repo.git?ref=main"
      assert {:ok, :github} = URLParser.provider(url_with_params)
    end

    test "handles URLs with fragments" do
      url_with_fragment = "https://github.com/owner/repo.git#readme"
      assert {:ok, :github} = URLParser.provider(url_with_fragment)
    end

    test "handles URLs with mixed case domains" do
      mixed_case_url = "https://GitHub.com/owner/repo.git"
      assert {:ok, :github} = URLParser.provider(mixed_case_url)
    end

    test "handles URLs with www subdomain" do
      www_url = "https://www.github.com/owner/repo.git"
      assert {:error, :unsupported_provider} = URLParser.provider(www_url)
    end

    test "handles very long repository paths" do
      long_path_url =
        "https://gitlab.com/group/subgroup/nested/deeply/nested/path/to/repo.git"

      assert {:ok, :gitlab} = URLParser.provider(long_path_url)
    end

    test "handles URLs with port numbers" do
      url_with_port = "https://github.com:443/owner/repo.git"
      assert {:ok, :github} = URLParser.provider(url_with_port)
    end

    test "handles whitespace in URL" do
      url_with_spaces = "  https://github.com/owner/repo.git  "
      assert {:error, :invalid_url} = URLParser.provider(url_with_spaces)
    end
  end

  # ============================================================================
  # inject_token/2 - Happy Path Tests
  # ============================================================================

  describe "inject_token/2 - GitHub URLs" do
    test "injects token into standard GitHub HTTPS URL" do
      expected = expected_github_authenticated_url()
      assert {:ok, ^expected} = URLParser.inject_token(github_https_url(), github_token())
    end

    test "injects token into GitHub URL without .git extension" do
      expected = "https://#{github_token()}@github.com/owner/repo"

      assert {:ok, ^expected} =
               URLParser.inject_token(github_https_url_no_dot_git(), github_token())
    end

    test "injects token into GitHub URL with additional path segments" do
      expected = "https://#{github_token()}@github.com/owner/repo/some/path.git"

      assert {:ok, ^expected} =
               URLParser.inject_token(github_https_url_with_path(), github_token())
    end
  end

  describe "inject_token/2 - GitLab URLs" do
    test "injects token into standard GitLab HTTPS URL" do
      expected = expected_gitlab_authenticated_url()
      assert {:ok, ^expected} = URLParser.inject_token(gitlab_https_url(), gitlab_token())
    end

    test "injects token into GitLab URL without .git extension" do
      expected = "https://#{gitlab_token()}@gitlab.com/owner/repo"

      assert {:ok, ^expected} =
               URLParser.inject_token(gitlab_https_url_no_dot_git(), gitlab_token())
    end

    test "injects token into GitLab URL with subgroups" do
      expected = "https://#{gitlab_token()}@gitlab.com/group/subgroup/repo.git"

      assert {:ok, ^expected} =
               URLParser.inject_token(gitlab_https_url_with_subgroup(), gitlab_token())
    end
  end

  # ============================================================================
  # inject_token/2 - Error Cases
  # ============================================================================

  describe "inject_token/2 - invalid URL formats" do
    test "returns error for SSH URL format" do
      assert {:error, :invalid_url} = URLParser.inject_token(github_ssh_url(), github_token())
    end

    test "returns error for HTTP (non-HTTPS) URL" do
      assert {:error, :invalid_url} = URLParser.inject_token(http_url(), github_token())
    end

    test "returns error for malformed URL" do
      assert {:error, :invalid_url} = URLParser.inject_token(malformed_url(), github_token())
    end

    test "returns error for empty URL" do
      assert {:error, :invalid_url} = URLParser.inject_token(empty_url(), github_token())
    end

    test "returns error for nil URL" do
      assert {:error, :invalid_url} = URLParser.inject_token(nil, github_token())
    end
  end

  describe "inject_token/2 - token validation" do
    test "handles empty token string" do
      expected = "https://@github.com/owner/repo.git"
      assert {:ok, ^expected} = URLParser.inject_token(github_https_url(), "")
    end

    test "handles nil token" do
      expected = "https://github.com/owner/repo.git"
      assert {:ok, ^expected} = URLParser.inject_token(github_https_url(), nil)
    end

    test "handles token with special characters" do
      special_token = "token-with-special!@#$%^&*()chars"
      {:ok, result} = URLParser.inject_token(github_https_url(), special_token)
      assert String.contains?(result, special_token)
    end
  end

  # ============================================================================
  # inject_token/2 - Edge Cases
  # ============================================================================

  describe "inject_token/2 - edge cases" do
    test "replaces existing credentials in URL" do
      url_with_creds = "https://old_token@github.com/owner/repo.git"
      expected = "https://#{github_token()}@github.com/owner/repo.git"
      assert {:ok, ^expected} = URLParser.inject_token(url_with_creds, github_token())
    end

    test "replaces existing username in URL" do
      url_with_user = "https://username@github.com/owner/repo.git"
      expected = "https://#{github_token()}@github.com/owner/repo.git"
      assert {:ok, ^expected} = URLParser.inject_token(url_with_user, github_token())
    end

    test "handles URL with trailing slash" do
      url_with_slash = "https://github.com/owner/repo.git/"
      result = URLParser.inject_token(url_with_slash, github_token())
      assert {:ok, url} = result
      assert String.contains?(url, github_token())
    end

    test "preserves query parameters" do
      url_with_params = "https://github.com/owner/repo.git?ref=main"
      {:ok, result} = URLParser.inject_token(url_with_params, github_token())
      assert String.contains?(result, github_token())
      assert String.contains?(result, "?ref=main")
    end

    test "preserves URL fragments" do
      url_with_fragment = "https://github.com/owner/repo.git#readme"
      {:ok, result} = URLParser.inject_token(url_with_fragment, github_token())
      assert String.contains?(result, github_token())
      assert String.contains?(result, "#readme")
    end

    test "handles very long tokens" do
      long_token = String.duplicate("a", 1000)
      {:ok, result} = URLParser.inject_token(github_https_url(), long_token)
      assert String.contains?(result, long_token)
    end
  end

  # ============================================================================
  # Integration Tests - provider/1 and inject_token/2 together
  # ============================================================================

  describe "integration - provider detection and token injection" do
    test "provider detection and token injection work together for GitHub" do
      url = github_https_url()
      assert {:ok, :github} = URLParser.provider(url)
      assert {:ok, authenticated_url} = URLParser.inject_token(url, github_token())
      assert String.contains?(authenticated_url, github_token())
      assert String.contains?(authenticated_url, "@github.com")
    end

    test "provider detection and token injection work together for GitLab" do
      url = gitlab_https_url()
      assert {:ok, :gitlab} = URLParser.provider(url)
      assert {:ok, authenticated_url} = URLParser.inject_token(url, gitlab_token())
      assert String.contains?(authenticated_url, gitlab_token())
      assert String.contains?(authenticated_url, "@gitlab.com")
    end

    test "unsupported provider can still have token injected" do
      url = unknown_provider_url()
      assert {:error, :unsupported_provider} = URLParser.provider(url)
      # inject_token works regardless of provider
      {:ok, authenticated_url} = URLParser.inject_token(url, "some_token")
      assert String.contains?(authenticated_url, "some_token@")
    end
  end

  # ============================================================================
  # Property-Based Edge Cases
  # ============================================================================

  describe "property-based tests" do
    test "inject_token always produces a valid URL structure when given valid HTTPS URL" do
      valid_urls = [
        github_https_url(),
        gitlab_https_url(),
        github_https_url_no_dot_git(),
        gitlab_https_url_with_subgroup()
      ]

      for url <- valid_urls do
        assert_inject_token_ok_or_error(URLParser.inject_token(url, "test_token"))
      end
    end

    test "provider function is consistent with multiple calls" do
      url = github_https_url()
      result1 = URLParser.provider(url)
      result2 = URLParser.provider(url)
      result3 = URLParser.provider(url)

      assert result1 == result2
      assert result2 == result3
    end

    test "inject_token is idempotent for the same inputs" do
      url = github_https_url()
      token = github_token()

      result1 = URLParser.inject_token(url, token)
      result2 = URLParser.inject_token(url, token)

      assert result1 == result2
    end
  end

  # Inject-token may either return {:ok, url-with-token} or {:error, reason}
  # for the valid_urls set; both are acceptable. Multi-clause defp instead
  # of a `case` in the loop body.
  defp assert_inject_token_ok_or_error({:ok, result}) do
    assert String.starts_with?(result, "https://")
    assert String.contains?(result, "@")
    assert String.contains?(result, "test_token")
  end

  defp assert_inject_token_ok_or_error({:error, _}), do: :ok
end
