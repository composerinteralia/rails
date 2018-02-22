# frozen_string_literal: true

require "active_record/relation/sql_literal"

module ActiveRecord
  module Sanitization
    extend ActiveSupport::Concern

    module ClassMethods
      # Accepts an array or string of SQL conditions and sanitizes
      # them into a valid SQL fragment for a WHERE clause.
      #
      #   sanitize_sql_for_conditions(["name=? and group_id=?", "foo'bar", 4])
      #   # => "name='foo''bar' and group_id=4"
      #
      #   sanitize_sql_for_conditions(["name=:name and group_id=:group_id", name: "foo'bar", group_id: 4])
      #   # => "name='foo''bar' and group_id='4'"
      #
      #   sanitize_sql_for_conditions(["name='%s' and group_id='%s'", "foo'bar", 4])
      #   # => "name='foo''bar' and group_id='4'"
      #
      #   sanitize_sql_for_conditions("name='foo''bar' and group_id='4'")
      #   # => "name='foo''bar' and group_id='4'"
      def sanitize_sql_for_conditions(condition)
        return nil if condition.blank?

        case condition
        when Array; sanitize_sql_array(condition)
        else        condition
        end
      end
      alias :sanitize_sql :sanitize_sql_for_conditions

      # Accepts an array, hash, or string of SQL conditions and sanitizes
      # them into a valid SQL fragment for a SET clause.
      #
      #   sanitize_sql_for_assignment(["name=? and group_id=?", nil, 4])
      #   # => "name=NULL and group_id=4"
      #
      #   sanitize_sql_for_assignment(["name=:name and group_id=:group_id", name: nil, group_id: 4])
      #   # => "name=NULL and group_id=4"
      #
      #   Post.sanitize_sql_for_assignment({ name: nil, group_id: 4 })
      #   # => "`posts`.`name` = NULL, `posts`.`group_id` = 4"
      #
      #   sanitize_sql_for_assignment("name=NULL and group_id='4'")
      #   # => "name=NULL and group_id='4'"
      def sanitize_sql_for_assignment(assignments, default_table_name = table_name)
        case assignments
        when Array; sanitize_sql_array(assignments)
        when Hash;  sanitize_sql_hash_for_assignment(assignments, default_table_name)
        else        assignments
        end
      end

      # Accepts an array, or string of SQL conditions and sanitizes
      # them into a valid SQL fragment for an ORDER clause.
      #
      #   sanitize_sql_for_order(["field(id, ?)", [1,3,2]])
      #   # => "field(id, 1,3,2)"
      #
      #   sanitize_sql_for_order("id ASC")
      #   # => "id ASC"
      def sanitize_sql_for_order(condition)
        if condition.is_a?(Array) && condition.first.to_s.include?("?")
          enforce_raw_sql_whitelist([condition.first],
            whitelist: AttributeMethods::ClassMethods::COLUMN_NAME_ORDER_WHITELIST
          )

          # Ensure we aren't dealing with a subclass of String that might
          # override methods we use (eg. Arel::Nodes::SqlLiteral).
          if condition.first.kind_of?(String) && !condition.first.instance_of?(String)
            condition = [String.new(condition.first), *condition[1..-1]]
          end

          Arel.sql(sanitize_sql_array(condition))
        else
          condition
        end
      end

      # Sanitizes a hash of attribute/value pairs into SQL conditions for a SET clause.
      #
      #   sanitize_sql_hash_for_assignment({ status: nil, group_id: 1 }, "posts")
      #   # => "`posts`.`status` = NULL, `posts`.`group_id` = 1"
      def sanitize_sql_hash_for_assignment(attrs, table)
        c = connection
        attrs.map do |attr, value|
          type = type_for_attribute(attr)
          value = type.serialize(type.cast(value))
          "#{c.quote_table_name_for_assignment(table, attr)} = #{c.quote(value)}"
        end.join(", ")
      end

      # Sanitizes a +string+ so that it is safe to use within an SQL
      # LIKE statement. This method uses +escape_character+ to escape all occurrences of "\", "_" and "%".
      #
      #   sanitize_sql_like("100%")
      #   # => "100\\%"
      #
      #   sanitize_sql_like("snake_cased_string")
      #   # => "snake\\_cased\\_string"
      #
      #   sanitize_sql_like("100%", "!")
      #   # => "100!%"
      #
      #   sanitize_sql_like("snake_cased_string", "!")
      #   # => "snake!_cased!_string"
      def sanitize_sql_like(string, escape_character = "\\")
        pattern = Regexp.union(escape_character, "%", "_")
        string.gsub(pattern) { |x| [escape_character, x].join }
      end

      # Accepts an array of conditions. The array has each value
      # sanitized and interpolated into the SQL statement.
      #
      #   sanitize_sql_array(["name=? and group_id=?", "foo'bar", 4])
      #   # => "name='foo''bar' and group_id=4"
      #
      #   sanitize_sql_array(["name=:name and group_id=:group_id", name: "foo'bar", group_id: 4])
      #   # => "name='foo''bar' and group_id=4"
      #
      #   sanitize_sql_array(["name='%s' and group_id='%s'", "foo'bar", 4])
      #   # => "name='foo''bar' and group_id='4'"
      def sanitize_sql_array(ary)
        conn = connection
        collector = Arel::Collectors::SubstituteBinds.new(
          conn, Arel::Collectors::PlainString.new
        )

        SqlLiteral.new(conn, *ary).visit(collector)

        collector.value
      end

      private
        # Accepts a hash of SQL conditions and replaces those attributes
        # that correspond to a {#composed_of}[rdoc-ref:Aggregations::ClassMethods#composed_of]
        # relationship with their expanded aggregate attribute values.
        #
        # Given:
        #
        #   class Person < ActiveRecord::Base
        #     composed_of :address, class_name: "Address",
        #       mapping: [%w(address_street street), %w(address_city city)]
        #   end
        #
        # Then:
        #
        #   { address: Address.new("813 abc st.", "chicago") }
        #   # => { address_street: "813 abc st.", address_city: "chicago" }
        def expand_hash_conditions_for_aggregates(attrs) # :doc:
          expanded_attrs = {}
          attrs.each do |attr, value|
            if aggregation = reflect_on_aggregation(attr.to_sym)
              mapping = aggregation.mapping
              mapping.each do |field_attr, aggregate_attr|
                expanded_attrs[field_attr] = if value.is_a?(Array)
                  value.map { |it| it.send(aggregate_attr) }
                elsif mapping.size == 1 && !value.respond_to?(aggregate_attr)
                  value
                else
                  value.send(aggregate_attr)
                end
              end
            else
              expanded_attrs[attr] = value
            end
          end
          expanded_attrs
        end
        deprecate :expand_hash_conditions_for_aggregates
    end
  end
end
