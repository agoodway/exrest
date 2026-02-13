defmodule PgRest.Parser.EmbedFilterTest do
  use ExUnit.Case

  alias PgRest.Parser

  describe "parse/2 - embed dot-notation filters" do
    test "parses dot-notation embed filter when embed is in select" do
      params = %{
        "select" => "id,posts(id,title)",
        "posts.status" => "eq.published"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.filters == []

      assert result.embed_filters == %{
               "posts" => [%{field: "status", operator: :eq, value: "published"}]
             }
    end

    test "parses multiple dot-notation filters on same embed" do
      params = %{
        "select" => "id,posts(id,title)",
        "posts.status" => "eq.published",
        "posts.title" => "like.%Elixir%"
      }

      assert {:ok, result} = Parser.parse(params)
      assert length(result.embed_filters["posts"]) == 2
    end

    test "parses dot-notation filters on different embeds" do
      params = %{
        "select" => "id,posts(id),comments(body)",
        "posts.status" => "eq.published",
        "comments.status" => "eq.approved"
      }

      assert {:ok, result} = Parser.parse(params)
      assert Map.has_key?(result.embed_filters, "posts")
      assert Map.has_key?(result.embed_filters, "comments")
    end

    test "dot-notation with in operator" do
      params = %{
        "select" => "id,posts(id)",
        "posts.status" => "in.(published,draft)"
      }

      assert {:ok, result} = Parser.parse(params)
      [filter] = result.embed_filters["posts"]
      assert filter.operator == :in
      assert filter.value == ["published", "draft"]
    end

    test "dot-notation param ignored when embed not in select" do
      params = %{
        "select" => "id,name",
        "posts.status" => "eq.published"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.embed_filters == %{}
    end

    test "dot-notation filter not treated as root filter" do
      params = %{
        "select" => "id,posts(id)",
        "posts.status" => "eq.published",
        "name" => "eq.test"
      }

      assert {:ok, result} = Parser.parse(params)
      assert length(result.filters) == 1
      assert hd(result.filters).field == "name"
    end
  end

  describe "parse/2 - embed existence filters (anti-join)" do
    test "parses embed=is.null as embed existence filter" do
      params = %{
        "select" => "id,posts()",
        "posts" => "is.null"
      }

      assert {:ok, result} = Parser.parse(params)
      assert [filter] = result.embed_filters["posts"]
      assert filter.field == :__embed_exists__
      assert filter.operator == :is_null
      assert filter.value == true
    end

    test "parses embed=is.not_null as embed existence filter" do
      params = %{
        "select" => "id,posts()",
        "posts" => "is.not_null"
      }

      assert {:ok, result} = Parser.parse(params)
      assert [filter] = result.embed_filters["posts"]
      assert filter.field == :__embed_exists__
      assert filter.operator == :is_null
      assert filter.value == false
    end

    test "embed existence filter not treated as root filter" do
      params = %{
        "select" => "id,posts()",
        "posts" => "is.null"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.filters == []
    end
  end

  describe "parse/2 - embed filters not in custom_params" do
    test "dot-notation embed filters excluded from custom_params" do
      params = %{
        "select" => "id,posts(id)",
        "posts.status" => "eq.published",
        "status" => "eq.active",
        "search" => "foo"
      }

      assert {:ok, result} = Parser.parse(params, allowed_fields: [:status])
      assert result.custom_params == %{"search" => "foo"}
      refute Map.has_key?(result.custom_params, "posts.status")
    end

    test "embed existence filters excluded from custom_params" do
      params = %{
        "select" => "id,posts()",
        "posts" => "is.null",
        "search" => "foo"
      }

      assert {:ok, result} = Parser.parse(params, allowed_fields: [])
      assert result.custom_params == %{"search" => "foo"}
      refute Map.has_key?(result.custom_params, "posts")
    end
  end

  describe "parse/2 - embed filters with no select" do
    test "dot-notation ignored when no select param" do
      params = %{
        "posts.status" => "eq.published"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.embed_filters == %{}
    end
  end

  describe "parse/2 - nested dot-notation filters" do
    test "two-level dot notation stores with composite key" do
      params = %{
        "select" => "id,posts(id,comments(body))",
        "posts.comments.status" => "eq.approved"
      }

      assert {:ok, result} = Parser.parse(params)
      assert [filter] = result.embed_filters["posts.comments"]
      assert filter.field == "status"
      assert filter.operator == :eq
      assert filter.value == "approved"
    end

    test "three-level dot notation" do
      params = %{
        "select" => "id,posts(id,comments(body,replies(text)))",
        "posts.comments.replies.status" => "eq.active"
      }

      assert {:ok, result} = Parser.parse(params)
      assert [filter] = result.embed_filters["posts.comments.replies"]
      assert filter.field == "status"
    end

    test "nested dot-notation ignored when first-level embed not in select" do
      params = %{
        "select" => "id,name",
        "posts.comments.status" => "eq.approved"
      }

      assert {:ok, result} = Parser.parse(params, allowed_fields: [:id, :name])
      assert result.embed_filters == %{}
    end

    test "filters at first and second level simultaneously" do
      params = %{
        "select" => "id,posts(id,comments(body))",
        "posts.status" => "eq.published",
        "posts.comments.status" => "eq.approved"
      }

      assert {:ok, result} = Parser.parse(params)
      assert [post_filter] = result.embed_filters["posts"]
      assert post_filter.field == "status"
      assert post_filter.value == "published"

      assert [comment_filter] = result.embed_filters["posts.comments"]
      assert comment_filter.field == "status"
      assert comment_filter.value == "approved"
    end
  end
end
