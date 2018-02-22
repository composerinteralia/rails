# frozen_string_literal: true

require "active_record/relation/sql_literal"

module Arel
  module Nodes
    class LiteralSequence < Node
      def initialize(literals)
        @literals = literals
      end

      attr_reader :literals
    end
  end

  module Visitors
    class ToSql
      def visit_Arel_Nodes_LiteralSequence o, collector
        o.literals.each do |literal|
          visit literal, collector
        end

        collector
      end
    end

    class Dot
      def visit_Arel_Nodes_LiteralSequence o
        visit_edge o, "literals"
      end
    end
  end

  module Collectors
    class LiteralSequenceCollector
      def initialize
        @literals = []
      end

      def << str
        @literals << Arel.sql(str)
        self
      end

      def add_bind bind
        @literals << Arel::Nodes::BindParam.new(bind)
        self
      end

      def value
        Arel::Nodes::Grouping.new(Arel::Nodes::LiteralSequence.new(@literals))
      end
    end
  end
end

module ActiveRecord
  class Relation
    class WhereClauseFactory # :nodoc:
      def initialize(klass, predicate_builder)
        @klass = klass
        @predicate_builder = predicate_builder
      end

      def build(opts, other)
        case opts
        when String, Array
          all_opts = other.empty? ? opts : ([opts] + other)

          collector = Arel::Collectors::LiteralSequenceCollector.new
          SqlLiteral.new(klass.connection, *all_opts).visit(collector)
          parts = [collector.value]
        when Hash
          attributes = predicate_builder.resolve_column_aliases(opts)
          attributes.stringify_keys!

          parts = predicate_builder.build_from_hash(attributes)
        when Arel::Nodes::Node
          parts = [opts]
        else
          raise ArgumentError, "Unsupported argument type: #{opts} (#{opts.class})"
        end

        WhereClause.new(parts)
      end

      protected

        attr_reader :klass, :predicate_builder
    end
  end
end
