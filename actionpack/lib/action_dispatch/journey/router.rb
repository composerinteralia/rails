# frozen_string_literal: true

require "action_dispatch/journey/router/utils"
require "action_dispatch/journey/routes"
require "action_dispatch/journey/formatter"

before = $-w
$-w = false
require "action_dispatch/journey/parser"
$-w = before

require "action_dispatch/journey/route"
require "action_dispatch/journey/path/pattern"

module ActionDispatch
  module Journey # :nodoc:
    class Router # :nodoc:
      attr_accessor :routes

      def initialize(routes)
        @routes = routes
      end

      def eager_load!
        # Eagerly trigger the simulator's initialization so
        # it doesn't happen during a request cycle.
        simulator
        nil
      end

      def serve(req)
        find_routes(req).each do |match, parameters, route|
          set_params  = req.path_parameters
          path_info   = req.path_info
          script_name = req.script_name

          unless route.path.anchored
            req.script_name = (script_name.to_s + match.to_s).chomp("/")
            req.path_info = match.post_match
            req.path_info = "/" + req.path_info unless req.path_info.start_with? "/"
          end

          tmp_params = set_params.merge route.defaults
          parameters.each_pair { |key, val|
            tmp_params[key] = val.force_encoding(::Encoding::UTF_8)
          }

          req.path_parameters = tmp_params

          status, headers, body = route.app.serve(req)

          if "pass" == headers["X-Cascade"]
            req.script_name     = script_name
            req.path_info       = path_info
            req.path_parameters = set_params
            next
          end

          return [status, headers, body]
        end

        [404, { "X-Cascade" => "pass" }, ["Not Found"]]
      end

      def recognize(rails_req)
        find_routes(rails_req).each do |match, parameters, route|
          unless route.path.anchored
            rails_req.script_name = match.to_s
            rails_req.path_info   = match.post_match.sub(/^([^\/])/, '/\1')
          end

          parameters = route.defaults.merge parameters
          yield(route, parameters)
        end
      end

      def visualizer
        tt     = GTG::Builder.new(ast).transition_table
        groups = partitioned_routes.first.map(&:ast).group_by(&:to_s)
        asts   = groups.values.map(&:first)
        tt.visualizer(asts)
      end

      private
        def partitioned_routes
          routes.partition { |r|
            r.path.anchored && r.ast.all_default_regexp?
          }
        end

        def ast
          routes.ast
        end

        def simulator
          routes.simulator
        end

        def custom_routes
          routes.custom_routes
        end

        def filter_routes(path)
          return [] unless ast
          simulator.memos(path) { [] }
        end

        def find_routes(req)
          path_info = req.path_info
          routes = filter_routes(path_info).concat custom_routes.find_all { |r|
            r.path.match?(path_info)
          }

          if req.head?
            routes = match_head_routes(routes, req)
          else
            routes.select! { |r| r.matches?(req) }
          end

          routes.sort_by!(&:precedence)

          routes.map! { |r|
            match_data = r.path.match(path_info)
            path_parameters = {}
            match_data.names.each_with_index { |name, i|
              val = match_data[i + 1]
              path_parameters[name.to_sym] = Utils.unescape_uri(val) if val
            }
            [match_data, path_parameters, r]
          }
        end

        def match_head_routes(routes, req)
          head_routes = routes.select { |r| r.requires_matching_verb? && r.matches?(req) }
          return head_routes unless head_routes.empty?

          begin
            req.request_method = "GET"
            routes.select! { |r| r.matches?(req) }
            routes
          ensure
            req.request_method = "HEAD"
          end
        end
    end
  end
end
