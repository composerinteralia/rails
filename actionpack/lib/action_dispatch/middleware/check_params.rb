# frozen_string_literal: true

module ActionDispatch
  class CheckParams # :nodoc:
    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      request.parameters
      @app.call(env)
    end
  end
end
