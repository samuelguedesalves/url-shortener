defmodule ShortenerCore.Base62Test do
  use ExUnit.Case, async: true

  alias ShortenerCore.Base62

  describe "encode/1" do
    test "encodes zero" do
      assert Base62.encode(0) == "0"
    end

    test "encodes known values" do
      assert Base62.encode(61) == "z"
      assert Base62.encode(62) == "10"
      assert Base62.encode(125) == "21"
    end
  end

  describe "decode/1" do
    test "round-trips with encode" do
      for n <- [0, 1, 61, 62, 3_844, 1_000_000, 62 ** 7 - 1] do
        assert Base62.decode(Base62.encode(n)) == {:ok, n}
      end
    end

    test "rejects invalid characters and the empty string" do
      assert Base62.decode("ab-c") == :error
      assert Base62.decode("") == :error
      assert Base62.decode("a b") == :error
    end
  end

  describe "random/1" do
    test "returns exactly the requested length of base62 characters" do
      for length <- [1, 7, 32] do
        code = Base62.random(length)
        assert byte_size(code) == length
        assert code =~ ~r/\A[0-9A-Za-z]+\z/
      end
    end

    test "does not repeat across many draws" do
      codes = for _ <- 1..1_000, do: Base62.random(7)
      assert length(Enum.uniq(codes)) == 1_000
    end
  end
end
