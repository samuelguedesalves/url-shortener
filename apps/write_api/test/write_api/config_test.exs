defmodule WriteApi.ConfigTest do
  use ExUnit.Case, async: false

  alias WriteApi.Config
  alias WriteApi.Doubles

  test "passes when secrets are not required, whatever the secret" do
    Doubles.swap_env(:write_api, :session_secret, nil)
    assert Config.validate!() == :ok
  end

  defp swap_secret_key_base(value) do
    endpoint_env = Application.fetch_env!(:write_api, WriteApi.Endpoint)

    Doubles.swap_env(
      :write_api,
      WriteApi.Endpoint,
      Keyword.put(endpoint_env, :secret_key_base, value)
    )
  end

  test "passes with a secret of 32 bytes or more when secrets are required" do
    Doubles.swap_env(:write_api, :require_secrets, true)
    swap_secret_key_base(String.duplicate("k", 64))
    Doubles.swap_env(:write_api, :session_secret, String.duplicate("s", 32))
    assert Config.validate!() == :ok
  end

  test "raises when secrets are required and the session secret is missing" do
    Doubles.swap_env(:write_api, :require_secrets, true)
    Doubles.swap_env(:write_api, :session_secret, nil)
    assert_raise RuntimeError, ~r/SESSION_SECRET/, &Config.validate!/0
  end

  test "raises when secrets are required and the session secret is too short" do
    Doubles.swap_env(:write_api, :require_secrets, true)
    Doubles.swap_env(:write_api, :session_secret, String.duplicate("s", 31))
    assert_raise RuntimeError, ~r/SESSION_SECRET/, &Config.validate!/0
  end

  test "raises when the session secret is not a binary" do
    Doubles.swap_env(:write_api, :require_secrets, true)
    Doubles.swap_env(:write_api, :session_secret, 12_345)
    assert_raise RuntimeError, ~r/SESSION_SECRET/, &Config.validate!/0
  end

  describe "secret_key_base" do
    setup do
      Doubles.swap_env(:write_api, :require_secrets, true)
      Doubles.swap_env(:write_api, :session_secret, String.duplicate("s", 32))
    end

    test "raises when it is nil" do
      swap_secret_key_base(nil)
      assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, &Config.validate!/0
    end

    test "raises when it is 63 bytes" do
      swap_secret_key_base(String.duplicate("k", 63))
      assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, &Config.validate!/0
    end

    test "passes when it is 64 bytes" do
      swap_secret_key_base(String.duplicate("k", 64))
      assert Config.validate!() == :ok
    end

    test "is not checked when secrets are not required" do
      Doubles.swap_env(:write_api, :require_secrets, false)
      swap_secret_key_base(nil)
      assert Config.validate!() == :ok
    end
  end

  describe "google_client_id/0" do
    test "is nil when unset" do
      Doubles.swap_env(:write_api, :google_client_id, nil)
      assert Config.google_client_id() == nil
    end

    test "is nil when empty or blank" do
      Doubles.swap_env(:write_api, :google_client_id, "")
      assert Config.google_client_id() == nil
      Application.put_env(:write_api, :google_client_id, "   ")
      assert Config.google_client_id() == nil
    end

    test "is the trimmed value otherwise" do
      Doubles.swap_env(:write_api, :google_client_id, "  abc.apps.googleusercontent.com \n")
      assert Config.google_client_id() == "abc.apps.googleusercontent.com"
    end
  end
end
