defmodule ShortenerCore.UrlStoreContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.UrlStore` implementations (ADR 0004).

      use ShortenerCore.UrlStoreContract, store: MyStore
  """

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote do
      alias ShortenerCore.Url

      @store unquote(store)

      defp new_url(attrs \\ []) do
        now = DateTime.utc_now()

        struct!(
          Url,
          Keyword.merge(
            [
              code: "t" <> ShortenerCore.Base62.random(8),
              owner_id: nil,
              is_custom_alias: false,
              created_at: now,
              expires_at: DateTime.add(now, 3_600)
            ],
            attrs
          )
        )
      end

      test "fetch returns :not_found for an unknown code" do
        assert @store.fetch("t" <> ShortenerCore.Base62.random(8)) == :not_found
      end

      test "a claimed code with no destination fetches with long_url nil" do
        url = new_url()
        assert @store.claim(url) == :ok
        assert {:ok, %Url{long_url: nil, code: code}} = @store.fetch(url.code)
        assert code == url.code
      end

      test "claim stores the metadata" do
        url = new_url(owner_id: "owner-1", is_custom_alias: true)
        assert @store.claim(url) == :ok

        assert {:ok, fetched} = @store.fetch(url.code)
        assert fetched.owner_id == "owner-1"
        assert fetched.is_custom_alias == true
        assert DateTime.diff(fetched.expires_at, url.expires_at, :second) == 0
      end

      test "claiming a taken code returns {:error, :taken} and keeps the first row" do
        first = new_url(owner_id: "first")
        assert @store.claim(first) == :ok
        assert @store.claim(%Url{first | owner_id: "second"}) == {:error, :taken}
        assert {:ok, %Url{owner_id: "first"}} = @store.fetch(first.code)
      end

      test "put_destination makes the long url readable" do
        url = new_url()
        assert @store.claim(url) == :ok
        assert @store.put_destination(url.code, "https://example.com/a?b=1", 3_600) == :ok
        assert {:ok, %Url{long_url: "https://example.com/a?b=1"}} = @store.fetch(url.code)
      end

      test "after the TTL the destination is gone but the code stays claimed (ADR 0004)" do
        url = new_url()
        assert @store.claim(url) == :ok
        assert @store.put_destination(url.code, "https://example.com", 2) == :ok
        assert {:ok, %Url{long_url: "https://example.com"}} = @store.fetch(url.code)

        Process.sleep(2_500)

        assert {:ok, %Url{long_url: nil}} = @store.fetch(url.code)
        assert @store.claim(url) == {:error, :taken}
      end
    end
  end
end
