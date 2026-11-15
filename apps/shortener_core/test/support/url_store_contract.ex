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

      defp new_owner, do: "owner-" <> ShortenerCore.Base62.random(12)

      test "list_by_owner returns an empty list for an owner with no links" do
        assert @store.list_by_owner(new_owner(), 50, nil) == {:ok, []}
      end

      test "a claimed code appears in its owner's list with the stored metadata" do
        owner = new_owner()
        url = new_url(owner_id: owner, is_custom_alias: true)
        assert @store.claim(url) == :ok

        assert {:ok, [%Url{} = listed]} = @store.list_by_owner(owner, 50, nil)
        assert listed.code == url.code
        assert listed.owner_id == owner
        assert listed.is_custom_alias == true
        assert listed.long_url == nil
        assert DateTime.diff(listed.expires_at, url.expires_at, :second) == 0
      end

      test "list_by_owner includes the destination once it is stored" do
        owner = new_owner()
        url = new_url(owner_id: owner)
        assert @store.claim(url) == :ok
        assert @store.put_destination(url.code, "https://example.com/mine", 3_600) == :ok

        assert {:ok, [%Url{long_url: "https://example.com/mine"}]} =
                 @store.list_by_owner(owner, 50, nil)
      end

      test "list_by_owner returns the newest link first" do
        owner = new_owner()
        now = DateTime.utc_now()

        # Index 0 is the newest.
        urls =
          for age <- 0..2,
              do: new_url(owner_id: owner, created_at: DateTime.add(now, -age * 60, :second))

        for url <- Enum.shuffle(urls), do: assert(@store.claim(url) == :ok)

        assert {:ok, listed} = @store.list_by_owner(owner, 50, nil)
        assert Enum.map(listed, & &1.code) == Enum.map(urls, & &1.code)
      end

      test "list_by_owner returns only that owner's links" do
        mine = new_owner()
        theirs = new_owner()
        my_url = new_url(owner_id: mine)
        assert @store.claim(my_url) == :ok
        assert @store.claim(new_url(owner_id: theirs)) == :ok

        assert {:ok, [%Url{code: code}]} = @store.list_by_owner(mine, 50, nil)
        assert code == my_url.code
      end

      test "list_by_owner returns at most the limit, keeping the newest" do
        owner = new_owner()
        now = DateTime.utc_now()

        urls =
          for age <- 0..2,
              do: new_url(owner_id: owner, created_at: DateTime.add(now, -age * 60, :second))

        for url <- urls, do: assert(@store.claim(url) == :ok)

        assert {:ok, listed} = @store.list_by_owner(owner, 2, nil)
        assert Enum.map(listed, & &1.code) == urls |> Enum.take(2) |> Enum.map(& &1.code)
      end

      defp page_through(owner, limit, after_cursor \\ nil, acc \\ []) do
        assert {:ok, page} = @store.list_by_owner(owner, limit, after_cursor)

        case List.last(page) do
          nil ->
            {Enum.reverse(acc), :empty}

          last ->
            page_through(owner, limit, {last.created_at, last.code}, Enum.reverse(page, acc))
        end
      end

      test "list_by_owner pages with an after cursor" do
        owner = new_owner()
        now = DateTime.utc_now()

        urls =
          for age <- 0..4,
              do: new_url(owner_id: owner, created_at: DateTime.add(now, -age * 60, :second))

        for url <- Enum.shuffle(urls), do: assert(@store.claim(url) == :ok)

        assert {:ok, first} = @store.list_by_owner(owner, 2, nil)
        assert Enum.map(first, & &1.code) == urls |> Enum.take(2) |> Enum.map(& &1.code)

        assert {listed, :empty} = page_through(owner, 2)
        assert Enum.map(listed, & &1.code) == Enum.map(urls, & &1.code)

        last = List.last(urls)
        assert @store.list_by_owner(owner, 2, {last.created_at, last.code}) == {:ok, []}
      end

      test "list_by_owner pages through links sharing one created_at" do
        owner = new_owner()
        created_at = DateTime.utc_now()
        urls = for _ <- 1..5, do: new_url(owner_id: owner, created_at: created_at)
        for url <- Enum.shuffle(urls), do: assert(@store.claim(url) == :ok)

        assert {listed, :empty} = page_through(owner, 2)
        codes = Enum.map(listed, & &1.code)
        assert length(codes) == 5
        assert codes == urls |> Enum.map(& &1.code) |> Enum.sort()
      end

      test "a cursor in the middle of a timestamp joins the rest of it with older links" do
        owner = new_owner()
        newer_at = DateTime.utc_now()
        older_at = DateTime.add(newer_at, -60, :second)
        newer = for _ <- 1..3, do: new_url(owner_id: owner, created_at: newer_at)
        older = for _ <- 1..2, do: new_url(owner_id: owner, created_at: older_at)
        for url <- Enum.shuffle(newer ++ older), do: assert(@store.claim(url) == :ok)

        expected =
          Enum.sort(Enum.map(newer, & &1.code)) ++ Enum.sort(Enum.map(older, & &1.code))

        # Each cursor is built from the last listed link, as the API does (Cassandra stores
        # milliseconds, so the listed created_at may differ from the one claimed).
        pages =
          Stream.unfold(nil, fn
            :done ->
              nil

            after_cursor ->
              assert {:ok, page} = @store.list_by_owner(owner, 2, after_cursor)

              case List.last(page) do
                nil -> {page, :done}
                last -> {page, {last.created_at, last.code}}
              end
          end)
          |> Enum.to_list()

        assert Enum.map(pages, &Enum.map(&1, fn url -> url.code end)) ==
                 [
                   Enum.slice(expected, 0, 2),
                   Enum.slice(expected, 2, 2),
                   [List.last(expected)],
                   []
                 ]

        # The second page holds the last link at the newer time and the first older one.
        [_, [same_time, older_row], _, _] = pages
        assert same_time.code in Enum.map(newer, & &1.code)
        assert older_row.code in Enum.map(older, & &1.code)
        assert DateTime.compare(same_time.created_at, older_row.created_at) == :gt
      end

      test "after is scoped to the owner" do
        mine = new_owner()
        theirs = new_owner()
        now = DateTime.utc_now()

        my_urls =
          for age <- 0..2,
              do: new_url(owner_id: mine, created_at: DateTime.add(now, -age * 60, :second))

        their_urls =
          for age <- 0..2,
              do:
                new_url(owner_id: theirs, created_at: DateTime.add(now, -age * 60 - 30, :second))

        for url <- my_urls ++ their_urls, do: assert(@store.claim(url) == :ok)

        first = hd(my_urls)
        assert {:ok, listed} = @store.list_by_owner(mine, 50, {first.created_at, first.code})
        assert Enum.map(listed, & &1.code) == my_urls |> tl() |> Enum.map(& &1.code)
      end

      test "a claim that loses on a taken code does not list it under the second owner" do
        first_owner = new_owner()
        second_owner = new_owner()
        first = new_url(owner_id: first_owner)
        assert @store.claim(first) == :ok
        assert @store.claim(%Url{first | owner_id: second_owner}) == {:error, :taken}

        assert @store.list_by_owner(second_owner, 50, nil) == {:ok, []}
        assert {:ok, [%Url{owner_id: ^first_owner}]} = @store.list_by_owner(first_owner, 50, nil)
      end
    end
  end
end
