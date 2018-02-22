module ActiveRecord
  class SqlLiteral # :nodoc:
    attr_reader :statement, :values, :connection

    def initialize(connection, statement, *values)
      @connection = connection
      @statement = statement
      @values = values
    end

    def visit(collector)
      if named_binds?
        visit_named_binds(collector)
      elsif question_mark_binds?
        visit_question_mark_binds(collector)
      elsif values.empty?
        collector << statement
      else
        collector << (statement % values.collect { |value| connection.quote_string(value.to_s) })
      end
    end

    private

    def named_binds?
      Hash === values.first && /:\w+/ =~ (statement)
    end

    def question_mark_binds?
      statement.include?("?".freeze)
    end

    def visit_named_binds(collector)
      binds = values.first

      # Negative look behind for postgres casts
      statement.split(/(?<!:)(:[a-zA-Z]\w*)/).each do |literal|
        if literal =~ /^:([a-zA-Z]\w*$)/
          name = $1.to_sym
          if binds.include?(name)
            visit_bind_variable(name, binds[name], collector)
          else
            raise PreparedStatementInvalid, "missing value for :#{name} in #{statement}"
          end
        else
          collector << literal
        end
      end
    end

    def visit_question_mark_binds(collector)
      raise_if_bind_arity_mismatch(statement, statement.count("?".freeze), values.size)

      bind_values = values.dup

      statement.split(/(\?)/).each do |literal|
        if literal =~ /^\?$/
          visit_bind_variable("?".freeze, bind_values.shift, collector)
        else
          collector << literal
        end
      end
    end

    def visit_bind_variable(name, value, collector)
      if ActiveRecord::Relation === value
        collector << value.to_sql
      else
        if value.respond_to?(:map) && !value.acts_like?(:string)
          visit_bind_collection(name, value, collector)
        else
          val = Relation::QueryAttribute.new(name, value, ActiveModel::Type::Value.new)
          collector.add_bind(val)
        end
      end
    end

    def visit_bind_collection(name, value, collector)
      if value.respond_to?(:empty?) && value.empty?
        collector << connection.quote(nil)
      else
        value.each_with_index do |item, index|
          item = id_value_for_database(item) if item.is_a?(Base)

          bind = Relation::QueryAttribute.new("#{name}-#{index}", item, ActiveModel::Type::Value.new)

          collector.add_bind(bind)

          unless index == value.count - 1
            collector << ",".freeze
          end
        end
      end
    end

    def id_value_for_database(value)
      if primary_key = value.class.primary_key
        value.instance_variable_get(:@attributes)[primary_key].value_for_database
      end
    end

    def raise_if_bind_arity_mismatch(statement, expected, provided)
      unless expected == provided
        raise PreparedStatementInvalid, "wrong number of bind variables (#{provided} for #{expected}) in: #{statement}"
      end
    end
  end
end
