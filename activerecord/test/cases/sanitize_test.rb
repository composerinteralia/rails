# frozen_string_literal: true

require "cases/helper"
require "models/binary"
require "models/author"
require "models/post"
require "models/customer"

class SanitizeTest < ActiveRecord::TestCase
  def test_sanitize_sql_array_handles_string_interpolation
    quoted_bambi = ActiveRecord::Base.connection.quote_string("Bambi")
    assert_equal "name='#{quoted_bambi}'", Binary.sanitize_sql_array(["name='%s'", "Bambi"])
    assert_equal "name='#{quoted_bambi}'", Binary.sanitize_sql_array(["name='%s'", "Bambi".mb_chars])
    quoted_bambi_and_thumper = ActiveRecord::Base.connection.quote_string("Bambi\nand\nThumper")
    assert_equal "name='#{quoted_bambi_and_thumper}'", Binary.sanitize_sql_array(["name='%s'", "Bambi\nand\nThumper"])
    assert_equal "name='#{quoted_bambi_and_thumper}'", Binary.sanitize_sql_array(["name='%s'", "Bambi\nand\nThumper".mb_chars])
  end

  def test_sanitize_sql_array_handles_bind_variables
    quoted_bambi = ActiveRecord::Base.connection.quote("Bambi")
    assert_equal "name=#{quoted_bambi}", Binary.sanitize_sql_array(["name=?", "Bambi"])
    assert_equal "name=#{quoted_bambi}", Binary.sanitize_sql_array(["name=?", "Bambi".mb_chars])
    quoted_bambi_and_thumper = ActiveRecord::Base.connection.quote("Bambi\nand\nThumper")
    assert_equal "name=#{quoted_bambi_and_thumper}", Binary.sanitize_sql_array(["name=?", "Bambi\nand\nThumper"])
    assert_equal "name=#{quoted_bambi_and_thumper}", Binary.sanitize_sql_array(["name=?", "Bambi\nand\nThumper".mb_chars])
  end

  def test_sanitize_sql_array_handles_named_bind_variables
    quoted_bambi = ActiveRecord::Base.connection.quote("Bambi")
    assert_equal "name=#{quoted_bambi}", Binary.sanitize_sql_array(["name=:name", name: "Bambi"])
    assert_equal "name=#{quoted_bambi} AND id=1", Binary.sanitize_sql_array(["name=:name AND id=:id", name: "Bambi", id: 1])

    quoted_bambi_and_thumper = ActiveRecord::Base.connection.quote("Bambi\nand\nThumper")
    assert_equal "name=#{quoted_bambi_and_thumper}", Binary.sanitize_sql_array(["name=:name", name: "Bambi\nand\nThumper"])
    assert_equal "name=#{quoted_bambi_and_thumper} AND name2=#{quoted_bambi_and_thumper}", Binary.sanitize_sql_array(["name=:name AND name2=:name", name: "Bambi\nand\nThumper"])
  end

  def test_sanitize_sql_array_handles_relations
    david = Author.create!(name: "David")
    david_posts = david.posts.select(:id)

    sub_query_pattern = /\(\bselect\b.*?\bwhere\b.*?\)/i

    select_author_sql = Post.sanitize_sql_array(["id in (?)", david_posts])
    assert_match(sub_query_pattern, select_author_sql, "should sanitize `Relation` as subquery for bind variables")

    select_author_sql = Post.sanitize_sql_array(["id in (:post_ids)", post_ids: david_posts])
    assert_match(sub_query_pattern, select_author_sql, "should sanitize `Relation` as subquery for named bind variables")
  end

  def test_sanitize_sql_array_handles_empty_statement
    select_author_sql = Post.sanitize_sql_array([""])
    assert_equal("", select_author_sql)
  end

  def test_sanitize_sql_like
    assert_equal '100\%', Binary.sanitize_sql_like("100%")
    assert_equal 'snake\_cased\_string', Binary.sanitize_sql_like("snake_cased_string")
    assert_equal 'C:\\\\Programs\\\\MsPaint', Binary.sanitize_sql_like('C:\\Programs\\MsPaint')
    assert_equal "normal string 42", Binary.sanitize_sql_like("normal string 42")
  end

  def test_sanitize_sql_like_with_custom_escape_character
    assert_equal "100!%", Binary.sanitize_sql_like("100%", "!")
    assert_equal "snake!_cased!_string", Binary.sanitize_sql_like("snake_cased_string", "!")
    assert_equal "great!!", Binary.sanitize_sql_like("great!", "!")
    assert_equal 'C:\\Programs\\MsPaint', Binary.sanitize_sql_like('C:\\Programs\\MsPaint', "!")
    assert_equal "normal string 42", Binary.sanitize_sql_like("normal string 42", "!")
  end

  def test_bind_arity
    assert_raise(ActiveRecord::PreparedStatementInvalid) { sanitize "?" }
    assert_nothing_raised                                { sanitize "?", 1 }
    assert_raise(ActiveRecord::PreparedStatementInvalid) { sanitize "?", 1, 1 }
  end

  def test_named_bind_variables
    assert_equal "1", sanitize(":a", a: 1) # ' ruby-mode
    assert_equal "1 1", sanitize(":a :a", a: 1)  # ' ruby-mode

    assert_nothing_raised { sanitize("'+00:00'", foo: "bar") }
  end

  def test_named_bind_arity
    assert_nothing_raised                                { sanitize "name = :name", name: "37signals" }
    assert_nothing_raised                                { sanitize "name = :name", name: "37signals", id: 1 }
    assert_raise(ActiveRecord::PreparedStatementInvalid) { sanitize "name = :name", id: 1 }
  end

  class SimpleEnumerable
    include Enumerable

    def initialize(ary)
      @ary = ary
    end

    def each(&b)
      @ary.each(&b)
    end
  end

  def test_bind_enumerable
    quoted_abc = %(#{ActiveRecord::Base.connection.quote('a')},#{ActiveRecord::Base.connection.quote('b')},#{ActiveRecord::Base.connection.quote('c')})

    assert_equal "1,2,3", sanitize("?", [1, 2, 3])
    assert_equal quoted_abc, sanitize("?", %w(a b c))

    assert_equal "1,2,3", sanitize(":a", a: [1, 2, 3])
    assert_equal quoted_abc, sanitize(":a", a: %w(a b c)) # '

    assert_equal "1,2,3", sanitize("?", SimpleEnumerable.new([1, 2, 3]))
    assert_equal quoted_abc, sanitize("?", SimpleEnumerable.new(%w(a b c)))

    assert_equal "1,2,3", sanitize(":a", a: SimpleEnumerable.new([1, 2, 3]))
    assert_equal quoted_abc, sanitize(":a", a: SimpleEnumerable.new(%w(a b c))) # '
  end

  def test_bind_empty_enumerable
    quoted_nil = ActiveRecord::Base.connection.quote(nil)
    assert_equal quoted_nil, sanitize("?", [])
    assert_equal " in (#{quoted_nil})", sanitize(" in (?)", [])
    assert_equal "foo in (#{quoted_nil})", sanitize("foo in (?)", [])
  end

  def test_bind_empty_string
    quoted_empty = ActiveRecord::Base.connection.quote("")
    assert_equal quoted_empty, sanitize("?", "")
  end

  def test_bind_chars
    quoted_bambi = ActiveRecord::Base.connection.quote("Bambi")
    quoted_bambi_and_thumper = ActiveRecord::Base.connection.quote("Bambi\nand\nThumper")
    assert_equal "name=#{quoted_bambi}", sanitize("name=?", "Bambi")
    assert_equal "name=#{quoted_bambi_and_thumper}", sanitize("name=?", "Bambi\nand\nThumper")
    assert_equal "name=#{quoted_bambi}", sanitize("name=?", "Bambi".mb_chars)
    assert_equal "name=#{quoted_bambi_and_thumper}", sanitize("name=?", "Bambi\nand\nThumper".mb_chars)
  end

  def test_named_bind_with_postgresql_type_casts
    l = Proc.new { sanitize(":a::integer '2009-01-01'::date", a: "10") }
    assert_nothing_raised(&l)
    assert_equal "#{ActiveRecord::Base.connection.quote('10')}::integer '2009-01-01'::date", l.call
  end

  def test_deprecated_expand_hash_conditions_for_aggregates
    assert_deprecated do
      assert_equal({ "balance" => 50 }, Customer.send(:expand_hash_conditions_for_aggregates, balance: Money.new(50)))
    end
  end

  private
    def sanitize(*args)
      ActiveRecord::Base.sanitize_sql(args)
    end
end
