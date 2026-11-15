defmodule WriteApi.Auth.GoogleVerifierTest do
  use ExUnit.Case, async: false

  alias WriteApi.Auth.GoogleVerifier
  alias WriteApi.Auth.Jwks
  alias WriteApi.Doubles
  alias WriteApi.Doubles.StubJwksFetcher

  @client_id "test-client-id.apps.googleusercontent.com"
  @now 1_700_000_000

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048}), other_key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    Doubles.swap_env(:write_api, :google_client_id, @client_id)
    StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: 3600}})
    StubJwksFetcher.notify(self())
    on_exit(fn -> StubJwksFetcher.reset() end)
    restart_jwks()
    :ok
  end

  test "a valid token returns its claims with string keys", %{key: key} do
    token = sign(key, "kid-1", claims())

    assert {:ok, claims} = GoogleVerifier.verify(token, @now)
    assert claims["sub"] == "google-sub-1"
    assert claims["email"] == "ana@example.com"
    assert claims["email_verified"] == true
    assert claims["name"] == "Ana"
    assert claims["picture"] == "https://example.com/ana.png"
  end

  test "the iss without scheme is also accepted", %{key: key} do
    token = sign(key, "kid-1", claims(%{"iss" => "accounts.google.com"}))
    assert {:ok, _} = GoogleVerifier.verify(token, @now)
  end

  test "a token signed by another key is rejected", %{other_key: other_key} do
    token = sign(other_key, "kid-1", claims())
    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "a wrong aud is rejected", %{key: key} do
    token = sign(key, "kid-1", claims(%{"aud" => "someone-else"}))
    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "a wrong iss is rejected", %{key: key} do
    token = sign(key, "kid-1", claims(%{"iss" => "https://evil.example.com"}))
    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "an expired token is rejected", %{key: key} do
    token = sign(key, "kid-1", claims(%{"exp" => @now - 1}))
    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "an unverified email is rejected", %{key: key} do
    token = sign(key, "kid-1", claims(%{"email_verified" => false}))
    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "a token missing a required claim is rejected", %{key: key} do
    for missing <- ["sub", "email", "exp", "email_verified"] do
      token = sign(key, "kid-1", Map.delete(claims(), missing))
      assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}, missing
    end
  end

  test "an unset client id fails closed", %{key: key} do
    Application.put_env(:write_api, :google_client_id, nil)
    token = sign(key, "kid-1", claims(%{"aud" => nil}))
    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "non-JWT garbage is rejected" do
    for garbage <- ["", "not-a-jwt", "a.b.c", "....", "eyJhbGciOiJSUzI1NiJ9.e30."] do
      assert GoogleVerifier.verify(garbage, @now) == {:error, :invalid_token}, garbage
    end
  end

  test "a non-string credential is rejected" do
    assert GoogleVerifier.verify(nil, @now) == {:error, :invalid_token}
  end

  test "alg none is rejected" do
    header = b64(Jason.encode!(%{"alg" => "none", "kid" => "kid-1", "typ" => "JWT"}))
    payload = b64(Jason.encode!(claims()))

    assert GoogleVerifier.verify("#{header}.#{payload}.", @now) == {:error, :invalid_token}
  end

  test "an HS256 token is rejected even when keyed with the public key", %{key: key} do
    {_, public_pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    hmac = JOSE.JWK.from_oct(public_pem)

    {_, token} =
      hmac
      |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => "kid-1"}, claims())
      |> JOSE.JWS.compact()

    assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
  end

  test "an unknown kid refetches once and succeeds with the new key set", %{
    key: key,
    other_key: other_key
  } do
    assert {:ok, _} = GoogleVerifier.verify(sign(key, "kid-1", claims()), @now)
    assert_received :jwks_fetched

    StubJwksFetcher.set(
      {:ok, %{keys: [public_map(key, "kid-1"), public_map(other_key, "kid-2")], max_age: 3600}}
    )

    assert {:ok, _} = GoogleVerifier.verify(sign(other_key, "kid-2", claims()), @now)
    assert_received :jwks_fetched
    refute_received :jwks_fetched
  end

  test "an unknown kid that is still unknown after the refetch is rejected", %{
    other_key: other_key
  } do
    assert GoogleVerifier.verify(sign(other_key, "kid-9", claims()), @now) ==
             {:error, :invalid_token}

    assert_received :jwks_fetched
    refute_received :jwks_fetched
  end

  test "a known kid is served from the cache without fetching", %{key: key} do
    assert {:ok, _} = GoogleVerifier.verify(sign(key, "kid-1", claims()), @now)
    assert_received :jwks_fetched

    assert {:ok, _} = GoogleVerifier.verify(sign(key, "kid-1", claims()), @now)
    refute_received :jwks_fetched
  end

  test "a failing fetch with a warm cache still verifies", %{key: key} do
    StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: 0}})
    assert {:ok, _} = GoogleVerifier.verify(sign(key, "kid-1", claims()), @now)
    assert_received :jwks_fetched

    StubJwksFetcher.set({:error, :econnrefused})

    # max_age 0: the cache is stale, the refetch fails, and the stale key is served.
    assert {:ok, _} = GoogleVerifier.verify(sign(key, "kid-1", claims()), @now)
    assert_received :jwks_fetched
  end

  test "a failing fetch with no cache is unavailable", %{key: key} do
    StubJwksFetcher.set({:error, :econnrefused})

    assert GoogleVerifier.verify(sign(key, "kid-1", claims()), @now) == {:error, :unavailable}
  end

  describe "with a refetch cooldown" do
    setup do
      Doubles.swap_env(:write_api, :jwks_min_refetch_seconds, 30)
      Doubles.FakeClock.install(1_000_000)
      restart_jwks()
      :ok
    end

    test "many unknown kids within the cooldown cause a single fetch", %{other_key: other_key} do
      for n <- 1..20 do
        token = sign(other_key, "random-kid-#{n}", claims())
        assert GoogleVerifier.verify(token, @now) == {:error, :invalid_token}
      end

      assert_received :jwks_fetched
      refute_received :jwks_fetched
    end

    test "after a failed refresh the stale cache serves concurrent logins without refetching",
         %{key: key} do
      StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: 1}})
      token = sign(key, "kid-1", claims())
      assert {:ok, _} = GoogleVerifier.verify(token, @now)
      assert_received :jwks_fetched

      StubJwksFetcher.set({:error, :econnrefused})
      Doubles.FakeClock.advance(31_000)

      # The cache is stale and the cooldown has passed: one refresh is tried, fails, and the
      # stale key is served.
      assert {:ok, _} = GoogleVerifier.verify(token, @now)
      assert_received :jwks_fetched

      results =
        1..20
        |> Task.async_stream(fn _ -> GoogleVerifier.verify(token, @now) end, max_concurrency: 20)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
      refute_received :jwks_fetched

      # Once the cooldown passes the next lookup fetches again.
      Doubles.FakeClock.advance(30_000)
      assert {:ok, _} = GoogleVerifier.verify(token, @now)
      assert_received :jwks_fetched
      refute_received :jwks_fetched
    end

    test "a cold cache with a failed fetch stays unavailable without refetching in the cooldown",
         %{key: key} do
      StubJwksFetcher.set({:error, :econnrefused})
      token = sign(key, "kid-1", claims())

      assert GoogleVerifier.verify(token, @now) == {:error, :unavailable}
      assert_received :jwks_fetched

      Doubles.FakeClock.advance(29_000)
      assert GoogleVerifier.verify(token, @now) == {:error, :unavailable}
      refute_received :jwks_fetched
    end

    test "after the cooldown an unknown kid fetches again", %{key: key, other_key: other_key} do
      assert {:ok, _} = GoogleVerifier.verify(sign(key, "kid-1", claims()), @now)
      assert_received :jwks_fetched

      StubJwksFetcher.set(
        {:ok, %{keys: [public_map(key, "kid-1"), public_map(other_key, "kid-2")], max_age: 3600}}
      )

      new_token = sign(other_key, "kid-2", claims())
      assert GoogleVerifier.verify(new_token, @now) == {:error, :invalid_token}
      refute_received :jwks_fetched

      Doubles.FakeClock.advance(30_000)
      assert {:ok, _} = GoogleVerifier.verify(new_token, @now)
      assert_received :jwks_fetched
    end

    test "after the cooldown a cold cache fetches again", %{key: key} do
      StubJwksFetcher.set({:error, :econnrefused})
      token = sign(key, "kid-1", claims())
      assert GoogleVerifier.verify(token, @now) == {:error, :unavailable}
      assert_received :jwks_fetched

      StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: 3600}})
      Doubles.FakeClock.advance(30_000)
      assert {:ok, _} = GoogleVerifier.verify(token, @now)
      assert_received :jwks_fetched
    end

    @tag :capture_log
    test "a fetcher that raises, exits or throws with a cold cache is unavailable and keeps the process" do
      for failure <- [{:raise, "no CA store"}, {:exit, :boom}, {:throw, :boom}] do
        restart_jwks()
        StubJwksFetcher.set(failure)
        pid = Process.whereis(Jwks)

        assert Jwks.get_key("kid-1") == {:error, :unavailable}, inspect(failure)
        assert_received :jwks_fetched

        # Within the cooldown no lookup fetches again, and the process is the same one.
        for _ <- 1..10, do: assert(Jwks.get_key("kid-1") == {:error, :unavailable})
        refute_received :jwks_fetched
        assert Process.whereis(Jwks) == pid
        assert Process.alive?(pid)

        # After the cooldown the next lookup fetches once more.
        Doubles.FakeClock.advance(30_000)
        assert Jwks.get_key("kid-1") == {:error, :unavailable}
        assert_received :jwks_fetched
        refute_received :jwks_fetched
        assert Process.whereis(Jwks) == pid
      end
    end

    @tag :capture_log
    test "a fetcher that raises with a warm cache serves the stale keys", %{key: key} do
      StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: 1}})
      token = sign(key, "kid-1", claims())
      assert {:ok, _} = GoogleVerifier.verify(token, @now)
      assert_received :jwks_fetched
      pid = Process.whereis(Jwks)

      StubJwksFetcher.set({:raise, "no CA store"})
      Doubles.FakeClock.advance(31_000)

      assert {:ok, _} = GoogleVerifier.verify(token, @now)
      assert_received :jwks_fetched

      for _ <- 1..10, do: assert({:ok, _} = GoogleVerifier.verify(token, @now))
      refute_received :jwks_fetched
      assert Process.whereis(Jwks) == pid
      assert Process.alive?(pid)
    end

    test "a bad max_age counts as a failed fetch", %{key: key} do
      for max_age <- ["3600", -1, nil, 1.5] do
        restart_jwks()
        StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: max_age}})
        pid = Process.whereis(Jwks)

        assert Jwks.get_key("kid-1") == {:error, :unavailable}, inspect(max_age)
        assert_received :jwks_fetched

        for _ <- 1..10, do: assert(Jwks.get_key("kid-1") == {:error, :unavailable})
        refute_received :jwks_fetched
        assert Process.whereis(Jwks) == pid
      end
    end

    test "a bad max_age with a warm cache serves the stale keys", %{key: key} do
      StubJwksFetcher.set({:ok, %{keys: [public_map(key, "kid-1")], max_age: 1}})
      assert {:ok, _} = Jwks.get_key("kid-1")
      assert_received :jwks_fetched
      pid = Process.whereis(Jwks)

      StubJwksFetcher.set({:ok, %{keys: [], max_age: "soon"}})
      Doubles.FakeClock.advance(31_000)

      assert {:ok, _} = Jwks.get_key("kid-1")
      assert_received :jwks_fetched

      for _ <- 1..10, do: assert({:ok, _} = Jwks.get_key("kid-1"))
      refute_received :jwks_fetched
      assert Process.whereis(Jwks) == pid
    end
  end

  test "the facade calls the configured verifier" do
    WriteApi.Doubles.FakeVerifier.allow("cred-1", %{"sub" => "s"})

    assert WriteApi.Auth.Verifier.verify("cred-1") == {:ok, %{"sub" => "s"}}
    assert WriteApi.Auth.Verifier.verify("cred-2") == {:error, :invalid_token}
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => "https://accounts.google.com",
        "aud" => @client_id,
        "sub" => "google-sub-1",
        "email" => "ana@example.com",
        "email_verified" => true,
        "name" => "Ana",
        "picture" => "https://example.com/ana.png",
        "iat" => @now - 60,
        "exp" => @now + 3600
      },
      overrides
    )
  end

  defp sign(key, kid, claims) do
    {_, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid, "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp public_map(key, kid) do
    {_, map} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.merge(map, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
  end

  defp b64(data), do: Base.url_encode64(data, padding: false)

  defp restart_jwks do
    :ok = Supervisor.terminate_child(WriteApi.Supervisor, WriteApi.Auth.Jwks)
    {:ok, _} = Supervisor.restart_child(WriteApi.Supervisor, WriteApi.Auth.Jwks)
  end
end
