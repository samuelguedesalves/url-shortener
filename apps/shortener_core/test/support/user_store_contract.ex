defmodule ShortenerCore.UserStoreContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.UserStore` implementations.

      use ShortenerCore.UserStoreContract, store: MyStore
  """

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote do
      alias ShortenerCore.{Base62, User, Uuid}

      @store unquote(store)

      defp new_user(attrs \\ []) do
        now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

        struct!(
          User,
          Keyword.merge(
            [
              id: Uuid.generate(),
              google_id: "g" <> Base62.random(20),
              email: "user-" <> Base62.random(8) <> "@example.com",
              name: "Ada Lovelace",
              picture_url: "https://example.com/ada.jpg",
              email_verified: true,
              created_at: now,
              updated_at: now
            ],
            attrs
          )
        )
      end

      defp assert_same_user(%User{} = actual, %User{} = expected) do
        assert actual.id == expected.id
        assert actual.google_id == expected.google_id
        assert actual.email == expected.email
        assert actual.name == expected.name
        assert actual.picture_url == expected.picture_url
        assert actual.email_verified == expected.email_verified
        assert DateTime.compare(actual.created_at, expected.created_at) == :eq
        assert DateTime.compare(actual.updated_at, expected.updated_at) == :eq
      end

      test "get returns :not_found for an unknown id" do
        assert @store.get(Uuid.generate()) == :not_found
      end

      test "get_by_google_id returns :not_found for an unknown google id" do
        assert @store.get_by_google_id("g" <> Base62.random(20)) == :not_found
      end

      test "put then get returns every field" do
        user = new_user()
        assert @store.put(user) == :ok
        assert {:ok, fetched} = @store.get(user.id)
        assert_same_user(fetched, user)
      end

      test "a user without a picture round-trips with picture_url nil" do
        user = new_user(picture_url: nil, email_verified: false)
        assert @store.put(user) == :ok
        assert {:ok, %User{picture_url: nil, email_verified: false}} = @store.get(user.id)
      end

      test "put on an existing id replaces the profile" do
        user = new_user()
        assert @store.put(user) == :ok

        later = DateTime.add(user.updated_at, 60, :second)
        changed = %User{user | name: "Ada King", picture_url: nil, updated_at: later}
        assert @store.put(changed) == :ok

        assert {:ok, fetched} = @store.get(user.id)
        assert_same_user(fetched, changed)
      end

      test "claim_google_id returns the given user id the first time" do
        google_id = "g" <> Base62.random(20)
        user_id = Uuid.generate()
        assert @store.claim_google_id(google_id, user_id) == {:ok, user_id}
      end

      test "claim_google_id returns the first user id when the google id is already claimed" do
        google_id = "g" <> Base62.random(20)
        first = Uuid.generate()
        assert @store.claim_google_id(google_id, first) == {:ok, first}
        assert @store.claim_google_id(google_id, Uuid.generate()) == {:ok, first}
        assert @store.claim_google_id(google_id, first) == {:ok, first}
      end

      test "concurrent claims of one google id all agree on a single user id" do
        google_id = "g" <> Base62.random(20)

        results =
          1..20
          |> Task.async_stream(fn _ -> @store.claim_google_id(google_id, Uuid.generate()) end,
            max_concurrency: 20
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert [{:ok, _winner}] = Enum.uniq(results)
      end

      test "get_by_google_id is :not_found while the id is claimed but the user row is not written" do
        user = new_user()
        assert @store.claim_google_id(user.google_id, user.id) == {:ok, user.id}
        assert @store.get_by_google_id(user.google_id) == :not_found
      end

      test "get_by_google_id returns the user once it is claimed and written" do
        user = new_user()
        assert @store.claim_google_id(user.google_id, user.id) == {:ok, user.id}
        assert @store.put(user) == :ok
        assert {:ok, fetched} = @store.get_by_google_id(user.google_id)
        assert_same_user(fetched, user)
      end
    end
  end
end
