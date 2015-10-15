require 'volt'

module Volt
  # The Routes class takes a set of routes and sets up methods to go from
  # a url to params, and params to url.
  # routes do
  #   client "/about", _view: 'about'
  #   client "/blog/{id}/edit", _view: 'blog/edit', _action: 'edit'
  #   client "/blog/{id}", _view: 'blog/show', _action: 'show'
  #   client "/blog", _view: 'blog'
  #   client "/blog/new", _view: 'blog/new', _action: 'new'
  #   client "/cool/{_name}", _view: 'cool'
  # end
  #
  # Using the routes above, we would generate the following:
  #
  # @direct_routes = {
  #   '/about' => {_view: 'about'},
  #   '/blog' => {_view: 'blog'}
  #   '/blog/new' => {_view: 'blog/new', _action: 'new'}
  # }
  #
  # -- nil represents a terminal
  # -- * represents any match
  # -- a number for a parameter means use the value in that number section
  #
  # @indirect_routes = {
  #     '*' => {
  #       'edit' => {
  #         nil => {id: 1, _view: 'blog/edit', _action: 'edit'}
  #       }
  #       nil => {id: 1, _view: 'blog/show', _action: 'show'}
  #     }
  #   }
  # }
  #
  # Match for params
  # @param_matches = [
  #   {id: nil, _view: 'blog/edit', _action: 'edit'} => Proc.new {|params| "/blog/#{params.id}/edit", params.reject {|k,v| k == :id }}
  # ]
  class Routes
    def initialize
      # Paths where there are no bindings (an optimization)
      @direct_routes   = {}

      # Paths with bindings
      @indirect_routes = {}

      # Matcher for going from params to url
      @param_matches   = {}

      [:client, :get, :post, :put, :patch, :delete, :options].each do |method|
        @direct_routes[method] = {}
        @indirect_routes[method] = {}
        @param_matches[method] = []
      end
    end

    def define(&block)
      instance_eval(&block)

      self
    end

    # Add a route
    def client(path, params = {})
      create_route(:client, path, params)
    end

    # Add server side routes
    
    def get(path, params)
      create_route(:get, path, params)
    end

    def post(path, params)
      create_route(:post, path, params)
    end

    def patch(path, params)
      create_route(:patch, path, params)
    end

    def put(path, params)
      create_route(:put, path, params)
    end

    def delete(path, params)
      create_route(:delete, path, params)
    end

    def options(path, params)
      create_route(:options, path, params)
    end

    #Create rest endpoints
    def rest(path, params)
      endpoints = (params.delete(:only) || [:index, :show, :create, :update, :destroy, :options]).to_a
      endpoints = endpoints - params.delete(:except).to_a
      endpoints.each do |endpoint|
        self.send(('restful_' + endpoint.to_s).to_sym, path, params)
      end
    end

    def restful_index(base_path, params)
      get(base_path, params.merge(action: 'index'))
    end

    def restful_create(base_path, params)
      post(base_path, params.merge(action: 'create'))
    end

    def restful_show(base_path, params)
      get(path_with_id(base_path), params.merge(action: 'show'))
    end

    def restful_update(base_path, params)
      put(path_with_id(base_path), params.merge(action: 'update'))
    end

    def restful_destroy(base_path, params)
      delete(path_with_id(base_path), params.merge(action: 'destroy'))
    end

    def restful_options(base_path, params)
      options(base_path, params.merge(action: 'options'))
    end

    # Takes in params and generates a path and the remaining params
    # that should be shown in the url.  The extra "unused" params
    # will be tacked onto the end of the url ?param1=value1, etc...
    #
    # returns the url and new params, or nil, nil if no match is found.
    def params_to_url(test_params)
      # Extract the desired method from the params
      method = test_params.delete(:method) || :client
      method = method.to_sym

      # Add in underscores
      test_params = test_params.each_with_object({}) do |(k, v), obj|
        obj[k.to_sym] = v
      end

      @param_matches[method].each do |param_matcher|
        # TODO: Maybe a deep dup?
        result, new_params = check_params_match(test_params.dup, param_matcher[0])

        return param_matcher[1].call(new_params) if result
      end

      [nil, nil]
    end

    # Takes in a path and returns the matching params.
    # returns params as a hash
    def url_to_params(*args)
      if args.size < 2
        path = args[0]
        method = :client
      else
        path = args[1]
        method = args[0].to_sym
      end

      # First try a direct match
      result = @direct_routes[method][path]
      return result if result

      # Next, split the url and walk the sections
      parts = url_parts(path)

      match_path(parts, parts, @indirect_routes[method])
    end

    private

    def create_route(method, path, params)
      params = params.symbolize_keys
      method = method.to_sym
      if has_binding?(path)
        add_indirect_path(@indirect_routes[method], path, params)
      else
        @direct_routes[method][path] = params
      end

      add_param_matcher(method, path, params)
    end

    # Recursively walk the @indirect_routes hash, return the params for a route, return
    # false for non-matches.
    def match_path(original_parts, remaining_parts, node)
      # Take off the top part and get the rest into a new array
      # part will be nil if we are out of parts (fancy how that works out, now
      # stand in wonder about how much someone thought this through, though
      # really I just got lucky)
      part, *parts = remaining_parts

      if part.nil?
        if node[part]
          # We found a match, replace the bindings and return
          # TODO: Handvle nested
          setup_bindings_in_params(original_parts, node[part])
        else
          false
        end
      elsif (new_node = node[part])
        # Direct match for section, continue
        match_path(original_parts, parts, new_node)
      elsif (new_node = node['*'])
        # Match on binding section
        match_path(original_parts, parts, new_node)
      end
    end

    # The params out of match_path will have integers in the params that came from bindings
    # in the url.  This replaces those with the values from the url.
    def setup_bindings_in_params(original_parts, params)
      # Create a copy of the params we can modify and return
      params = params.dup

      params.each_pair do |key, value|
        if value.is_a?(Fixnum)
          # Lookup the param's value in the original url parts
          params[key] = original_parts[value]
        end
      end

      params
    end

    # Build up the @indirect_routes data structure.
    # '*' means wildcard match anything
    # nil means a terminal, who's value will be the params.
    #
    # In the params, an integer vaule means the index of the wildcard
    def add_indirect_path(node, path, params)
      parts = url_parts(path)

      parts.each_with_index do |part, index|
        if has_binding?(part)
          # Strip off {{ and }}
          params[part[2...-2].strip.to_sym] = index

          # Set the part to be '*' (anything matcher)
          part = '*'
        end

        node = (node[part] ||= {})
      end

      node[nil] = params
    end

    def add_param_matcher(method, path, params)
      params = params.dup
      parts  = url_parts(path)

      parts.each_with_index do |part, index|
        if has_binding?(part)
          # Setup a nil param that can match anything, but gets
          # assigned into the url
          params[part[2...-2].strip.to_sym] = nil
        end
      end

      path_transformer = create_path_transformer(parts)

      @param_matches[method] << [params, path_transformer]
    end

    # Takes in url parts and returns a proc that takes in params and returns
    # a url with the bindings filled in, and params with the binding params
    # removed.  (So the remaining can be added onto the end of the url ?params1=...)
    def create_path_transformer(parts)
      lambda do |input_params|
        input_params = input_params.dup

        url = parts.map do |part|
          val = if has_binding?(part)
                  # Get the
                  binding = part[2...-2].strip.to_sym
                  input_params.delete(binding)
                else
                  part
                end

          val
        end.join('/')

        return '/' + url, input_params
      end
    end

    # Takes in a hash of params and checks to make sure keys in param_matcher
    # are in test_params.  Checks for equal value unless value in param_matcher
    # is nil.
    #
    # returns false or true, new_params - where the new params are a the params not
    # used in the basic match.  Later some of these may be inserted into the url.
    def check_params_match(test_params, param_matcher)
      param_matcher.each_pair do |key, value|
        if value.is_a?(Hash)
          if test_params[key]
            result = check_params_match(test_params[key], value)

            if result == false
              return false
            else
              test_params.delete(key)
            end
          else
            # test_params did not have matching key
            return false
          end
        elsif value.nil?
          return false unless test_params.key?(key)
        else
          if test_params[key] == value
            test_params.delete(key)
          else
            return false
          end
        end
      end

      [true, test_params]
    end

    def url_parts(path)
      path.split('/').reject(&:blank?)
    end

    # Check if a string has a binding in it
    def has_binding?(string)
      string.index('{{') && string.index('}}')
    end

    #Append an id to a given path
    def path_with_id(base_path)
      base_path + '/{{ id  }}'
    end
  end
end
