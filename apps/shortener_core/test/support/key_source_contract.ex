defmodule ShortenerCore.KeySourceContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.KeySource` implementations (ADR 0001).

      use ShortenerCore.KeySourceContract, source: MySource
  """

  defmacro __using__(opts) do
    source = Keyword.fetch!(opts, :source)

    quote do
      @source unquote(source)

      test "next_key returns a 7-character base62 code" do
        assert {:ok, code} = @source.next_key()
        assert code =~ ~r/\A[0-9A-Za-z]{7}\z/
      end

      test "next_key does not repeat across many calls" do
        codes = for _ <- 1..500, do: elem(@source.next_key(), 1)
        assert length(Enum.uniq(codes)) == 500
      end
    end
  end
end
